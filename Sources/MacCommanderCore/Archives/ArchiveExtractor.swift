import Darwin
import Foundation

/// Extraction runs in two steps. First, bsdtar unpacks the requested entries into a private staging folder
/// next to the destination. Then the transfer engine moves them into place, which brings conflicts,
/// progress and undo. Data safety:
/// - bsdtar runs without `-P`, so it refuses `..` and absolute entry names and won't extract through symlinks;
/// - staged items are found with `lstat` and never through a symlink, so nothing outside staging is ever moved;
/// - the only permanent delete is `removeStaging`, of the staging folder this run created.
///
/// Staged folders are made owner-writable (u+rwx): bsdtar restores modes such as `r-x`, and macOS can
/// neither move a folder without write permission to a new parent nor empty it.
public enum ArchiveExtractor {
    static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    static let stagingPrefix = ".mc-partial-"

    /// Extracts `entries` (paths inside the archive, "" = everything) into a new hidden staging folder
    /// `<destination>/.mc-partial-<UUID>` and returns the staged top-level items: for each requested entry
    /// the item at `staging/<entry>`, or for "" every top-level item of the staging folder.
    /// The caller moves them and must call `removeStaging`. On error, staging is removed before throwing.
    ///
    /// A non-zero bsdtar exit is a failure even if every requested item exists, because the data may be
    /// incomplete. It is mapped like a listing error (password required, incorrect, unsupported, unreadable).
    /// Cancelling the task terminates bsdtar and throws `CancellationError`.
    @concurrent public static func stage(
        _ entries: [String], from archive: URL, near destination: URL, password: String?
    ) async throws -> (staging: URL, items: [URL]) {
        try Task.checkCancellation()
        // No patterns would mean "everything".
        guard !entries.isEmpty else {
            throw ArchiveError.unreadable(message: String(localized: "There is nothing to extract."))
        }
        let requested = try normalized(entries)
        let fileManager = FileManager()
        let staging = destination.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var arguments = [
                "-x", "-f", archive.path, "-C", staging.path, "--no-same-owner",
                // Always pass a passphrase: without one bsdtar prompts "Enter passphrase:" forever.
                "--passphrase", password ?? UUID().uuidString, "--",
            ]
            if let requested { arguments += requested.map { pattern(for: $0.joined(separator: "/")) } }
            let output: ProcessOutput
            do {
                output = try await ProcessRunner.run(bsdtar, arguments)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ArchiveError.unreadable(message: error.localizedDescription)
            }
            if output.status != 0 {
                throw error(stderr: output.stderr, hadPassword: password != nil, requested: requested ?? [])
            }
            try Task.checkCancellation()
            makeFoldersOwnerWritable(staging)

            let items: [URL]
            if let requested {
                items = try requested.map { try stagedItem($0, in: staging) }
            } else {
                items = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            return (staging, items)
        } catch {
            removeStaging(staging)
            throw error
        }
    }

    /// Extracts the single `entry` (a file or folder inside `archive`) to exactly `target`, e.g. the URL a
    /// file promise receiver (Finder, the Desktop) asks for. Stages next to `target`, then renames the staged
    /// item into place exclusively, and removes staging. Never overwrites: if anything is at `target` (before
    /// staging or when the rename runs), it throws `CocoaError(.fileWriteFileExists)` and leaves it unchanged.
    /// No conflict dialog, progress or undo: the receiver owns the result.
    @concurrent public static func extract(_ entry: String, from archive: URL, to target: URL, password: String?)
        async throws
    {
        let exists = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
        var info = stat()
        if lstat(target.path, &info) == 0 { throw exists }
        guard !entry.split(separator: "/").filter({ $0 != "." }).isEmpty else { throw notInArchive(entry) }
        let (staging, items) = try await stage(
            [entry], from: archive, near: target.deletingLastPathComponent(), password: password)
        defer { removeStaging(staging) }
        guard let item = items.first else { throw notInArchive(entry) }
        try Task.checkCancellation()
        let code = FileTransfer.exclusiveRename(item, to: target)
        if code == EEXIST { throw exists }
        if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }

    /// Permanently removes a staging folder made by `stage`. Only `.mc-partial-*` folders are touched.
    public static func removeStaging(_ staging: URL) {
        guard staging.lastPathComponent.hasPrefix(stagingPrefix) else { return }
        makeFoldersOwnerWritable(staging)
        try? FileManager().removeItem(at: staging)
    }

    /// bsdtar pattern for an entry: `*`, `?`, `[`, `\` escaped with a backslash.
    static func pattern(for entry: String) -> String {
        var result = ""
        for character in entry {
            if "*?[\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// For "Extract All" with several top-level items: moves `items` (all directly in `staging`) into a new
    /// folder named `name`, or its keep-both name in `destination`, and returns that folder. The folder is
    /// made inside a private subfolder of staging, so its name can't collide with a staged item.
    @concurrent static func wrap(_ items: [URL], in staging: URL, named name: String, for destination: URL) async throws -> URL {
        let fileManager = FileManager()
        let finalName = NameGenerator.keepBothName(for: name, isDirectory: true, in: destination, fileManager: fileManager)
        let holder = staging.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        let folder = holder.appendingPathComponent(finalName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in items {
            try fileManager.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
        }
        return folder
    }

    // MARK: - Helpers

    /// Entry paths split into components; nil when everything ("") is requested. `.` components are
    /// dropped and `..` is refused. Duplicates are dropped (first one kept, in order), and so is an entry
    /// inside another requested entry, since the folder brings it along.
    private static func normalized(_ entries: [String]) throws -> [[String]]? {
        var result: [[String]] = []
        for entry in entries {
            let components = entry.split(separator: "/").map(String.init).filter { $0 != "." }
            if components.isEmpty { return nil }
            if components.contains("..") { throw notInArchive(entry) }
            if !result.contains(components) { result.append(components) }
        }
        return result.filter { item in
            !result.contains { other in other.count < item.count && Array(item.prefix(other.count)) == other }
        }
    }

    /// `staging/<components>`, reached only through real directories (`lstat`): a symlink extracted from the
    /// archive is never followed out of staging.
    private static func stagedItem(_ components: [String], in staging: URL) throws -> URL {
        var url = staging
        for (offset, component) in components.enumerated() {
            url = url.appendingPathComponent(component)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw notInArchive(components.joined(separator: "/")) }
            let isLast = offset == components.count - 1
            if !isLast && info.st_mode & S_IFMT != S_IFDIR { throw notInArchive(components.joined(separator: "/")) }
        }
        return url
    }

    /// Maps a failed run: bsdtar's "<pattern>: Not found in archive" names the first missing entry;
    /// everything else is mapped like a listing error.
    private static func error(stderr: String, hadPassword: Bool, requested: [[String]]) -> ArchiveError {
        let mapped = ArchiveCatalog.error(stderr: stderr, hadPassword: hadPassword)
        guard case .unreadable = mapped else { return mapped }
        let suffix = ": Not found in archive"
        for line in stderr.split(separator: "\n") where line.hasSuffix(suffix) {
            var pattern = String(line.dropLast(suffix.count))
            if pattern.hasPrefix("bsdtar: ") { pattern.removeFirst("bsdtar: ".count) }
            let entry = requested.first { Self.pattern(for: $0.joined(separator: "/")) == pattern }
            return notInArchive(entry?.joined(separator: "/") ?? pattern)
        }
        return mapped
    }

    /// Adds u+rwx to `folder` and every folder below it, found with `lstat` (symlinks are never followed),
    /// adding permission before listing so unreadable folders can be entered. Best effort.
    static func makeFoldersOwnerWritable(_ folder: URL) {
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        let wanted = info.st_mode | S_IRWXU
        if wanted != info.st_mode { chmod(folder.path, wanted & 0o7777) }
        guard let names = try? FileManager().contentsOfDirectory(atPath: folder.path) else { return }
        for name in names { makeFoldersOwnerWritable(folder.appendingPathComponent(name)) }
    }

    private static func notInArchive(_ entry: String) -> ArchiveError {
        let name = entry.split(separator: "/").last.map(String.init) ?? entry
        return .unreadable(message: String(localized: "“\(name)” isn’t in the archive."))
    }
}
