import Darwin
import Foundation

/// Finder-style "Compress": zip archives made with `/usr/bin/ditto`.
public enum Compressor {
    /// All `items` share one parent folder. Never overwrites: the archive name is chosen with
    /// `NameGenerator.uniqueName` and written via a temporary name in that folder, then moved
    /// into place with a non-replacing move (retry with the next name on EEXIST).
    ///
    /// One item gives `<name>.zip`; several give `Archive.zip` (`Archive 2.zip`, …) with the items at the
    /// archive root. Cancelling the task terminates ditto; every temporary item is removed on every exit
    /// path, and a cancelled run throws `CancellationError`.
    @concurrent public static func compress(_ items: [URL]) async throws -> URL {
        guard let first = items.first else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "There is nothing to compress.")])
        }
        let parent = first.deletingLastPathComponent()
        let parentPath = parent.standardizedFileURL.path
        guard items.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == parentPath }) else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Items can only be compressed together when they are in the same folder.")
                ])
        }
        let fileManager = FileManager()
        try Task.checkCancellation()

        // ditto writes here; the hidden name keeps the half-written archive out of the listing.
        let staging = parent.appendingPathComponent(".mc-partial-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }

        let base: String
        if items.count == 1 {
            base = first.lastPathComponent
            try await runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, staging.path])
        } else {
            base = String(localized: "Archive")
            let folder = try makeCloneFolder(near: parent, fileManager: fileManager)
            defer { try? fileManager.removeItem(at: folder.removing) }
            for item in items {
                try Task.checkCancellation()
                try cloneItem(item, into: folder.url)
            }
            try await runDitto(["-c", "-k", "--sequesterRsrc", folder.url.path, staging.path])
        }
        try Task.checkCancellation()
        return try moveIntoPlace(staging, base: base, in: parent, fileManager: fileManager)
    }

    // MARK: - Steps

    /// Renames the finished archive to the first free `<base>.zip` / `<base> n.zip`, never replacing.
    private static func moveIntoPlace(_ staging: URL, base: String, in parent: URL, fileManager: FileManager)
        throws -> URL
    {
        // EEXIST means something took the name since it was chosen; pick the next free one.
        for _ in 0..<100 {
            let target = parent.appendingPathComponent(
                NameGenerator.uniqueName(base: base, pathExtension: "zip", in: parent, fileManager: fileManager))
            let code = FileTransfer.exclusiveRename(staging, to: target)
            if code == 0 { return target }
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }

    /// A private, empty folder for the clones, on the volume of `parent` when possible (so the clones
    /// are cheap APFS clones), otherwise in the temporary directory. `removing` is what to delete afterwards.
    private static func makeCloneFolder(near parent: URL, fileManager: FileManager) throws -> (url: URL, removing: URL) {
        let container: URL
        if let replacement = try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)
        {
            // The replacement directory is created for this call alone.
            container = replacement
            let url = container.appendingPathComponent("Archive", isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            return (url, container)
        }
        container = fileManager.temporaryDirectory.appendingPathComponent(
            ".mc-partial-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        return (container, container)
    }

    /// Clones (or, where cloning is impossible, copies) `item` into `folder`, keeping its name.
    private static func cloneItem(_ item: URL, into folder: URL) throws {
        let target = folder.appendingPathComponent(item.lastPathComponent)
        let flags = copyfile_flags_t(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_CLONE)
        if copyfile(item.path, target.path, nil, flags) < 0 {
            let code = errno
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSFilePathErrorKey: item.path,
                    NSLocalizedDescriptionKey: String(
                        localized: "“\(item.lastPathComponent)” couldn’t be compressed: \(String(cString: strerror(code)))"),
                ])
        }
    }

    // MARK: - ditto

    /// Runs `/usr/bin/ditto`. A non-zero exit throws `CocoaError(.fileWriteUnknown)` with ditto's stderr
    /// as the description; cancelling terminates ditto and throws `CancellationError`.
    private static func runDitto(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments)
        if result.status != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSLocalizedDescriptionKey: message.isEmpty
                        ? String(localized: "The archive couldn’t be created (ditto exited with status \(result.status)).")
                        : message
                ])
        }
    }
}
