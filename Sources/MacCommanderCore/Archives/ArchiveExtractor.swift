import Darwin
import Foundation
import Synchronization

/// Extraction runs in two steps. First, bsdtar unpacks the requested entries into a private staging folder
/// next to the destination. Then the transfer engine moves them into place, which brings conflicts,
/// progress and undo. Data safety:
/// - bsdtar runs without `-P`, so it refuses `..` and absolute entry names and won't extract through symlinks;
/// - staged items are found with `lstat` and never through a symlink, so nothing outside staging is ever moved;
/// - the only permanent delete is `removeStaging`, of the staging folder this run created.
///
/// Staged folders are made owner-writable (u+rwx): bsdtar restores modes such as `r-x`, and macOS can
/// neither move a folder without write permission to a new parent nor empty it. Staged items get the
/// archive's quarantine attribute (bsdtar doesn't copy it).
public enum ArchiveExtractor {
    static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    static let stagingPrefix = ".mc-partial-"

    /// Test hook: called with each new staging folder right after it is created, before bsdtar runs.
    /// Called for every extraction in the process, so a hook must ignore staging folders it doesn't expect.
    static let afterStagingCreatedHook = Mutex<(@Sendable (URL) -> Void)?>(nil)

    /// Test hook: the placeholder passphrase for an archive (nil = a random one). Called for every extraction
    /// in the process, so a hook must return nil for archives it doesn't expect.
    static let placeholderPassphraseHook = Mutex<(@Sendable (URL) -> String?)?>(nil)

    /// Passed when no password is known: without a passphrase bsdtar prompts "Enter passphrase:" forever.
    private static func placeholderPassphrase(for archive: URL) -> String {
        placeholderPassphraseHook.withLock { $0 }?(archive) ?? UUID().uuidString
    }

    /// Extracts `entries` (paths inside the archive, "" = everything) into a new hidden staging folder
    /// `<destination>/.mc-partial-<UUID>` and returns the staged top-level items: for each requested entry
    /// the item at `staging/<entry>`, or for "" every top-level item of the staging folder (`__MACOSX`
    /// folders left out; an archive with nothing else throws "The archive is empty.").
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
            throw ArchiveError.unreadable(message: L10n.string("archive.error.nothingToExtract", "There is nothing to extract."))
        }
        let requested = try normalized(entries)
        let fileManager = FileManager()
        let staging = destination.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            afterStagingCreatedHook.withLock { $0 }?(staging)
            var output = try await unpack(
                archive, into: staging, passphrase: password ?? placeholderPassphrase(for: archive),
                requested: requested)
            // Classic zip encryption checks a passphrase against one byte only, so about one wrong passphrase in
            // 256 passes and the entry then fails its CRC check instead. Without a password that passphrase was
            // the placeholder: one more try with another placeholder tells a password-protected archive (which
            // now asks for its password) from a damaged one (which fails the same way again).
            if output.status != 0, password == nil, ArchiveCatalog.isChecksumFailure(output.stderr) {
                removeStaging(staging)
                try fileManager.createDirectory(
                    at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                output = try await unpack(
                    archive, into: staging, passphrase: placeholderPassphrase(for: archive), requested: requested)
            }
            if output.status != 0 {
                throw error(stderr: output.stderr, hadPassword: password != nil, requested: requested ?? [])
            }
            try Task.checkCancellation()
            makeFoldersOwnerWritable(staging)
            if let quarantine = quarantine(of: archive) { setQuarantine(quarantine, below: staging) }

            let items: [URL]
            if let requested {
                items = try requested.map { try stagedItem($0, in: staging) }
            } else {
                items = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                if items.isEmpty {
                    throw ArchiveError.unreadable(message: L10n.string("archive.error.empty", "The archive is empty."))
                }
            }
            return (staging, items)
        } catch {
            removeStaging(staging)
            throw error
        }
    }

    /// Runs bsdtar to unpack `requested` (nil = everything but `__MACOSX`) from `archive` into `staging`.
    private static func unpack(
        _ archive: URL, into staging: URL, passphrase: String, requested: [[String]]?
    ) async throws -> ProcessOutput {
        var arguments = [
            "-x", "-f", archive.path, "-C", staging.path, "--no-same-owner", "--passphrase", passphrase,
        ]
        if let requested {
            arguments += ["--"] + requested.map { pattern(for: $0.joined(separator: "/")) }
        } else {
            // Everything except macOS resource-fork folders; the pattern matches them at any depth.
            arguments += ["--exclude", "__MACOSX"]
        }
        do {
            return try await ProcessRunner.run(bsdtar, arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ArchiveError.unreadable(message: error.localizedDescription)
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

    static let quarantineName = "com.apple.quarantine"

    /// The archive's `com.apple.quarantine` value, or nil when it has none.
    private static func quarantine(of archive: URL) -> [UInt8]? {
        let size = getxattr(archive.path, quarantineName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(archive.path, quarantineName, &value, size, 0, 0) == size else { return nil }
        return value
    }

    /// Gives every item below `folder` the quarantine `value`, as Archive Utility does, so Gatekeeper still
    /// checks a downloaded app or script. Items are found with `lstat`, and the attribute is set on links
    /// themselves (`XATTR_NOFOLLOW`), never on what they point to. Folders are owner-writable already;
    /// a read-only file gets u+w just for the call. Best effort.
    private static func setQuarantine(_ value: [UInt8], below folder: URL) {
        guard let names = try? FileManager().contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            let url = folder.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if setxattr(url.path, quarantineName, value, value.count, 0, XATTR_NOFOLLOW) != 0, errno == EACCES,
                type == S_IFREG, chmod(url.path, (info.st_mode | S_IWUSR) & 0o7777) == 0
            {
                setxattr(url.path, quarantineName, value, value.count, 0, XATTR_NOFOLLOW)
                chmod(url.path, info.st_mode & 0o7777)
            }
            if type == S_IFDIR { setQuarantine(value, below: url) }
        }
    }

    private static func notInArchive(_ entry: String) -> ArchiveError {
        let name = entry.split(separator: "/").last.map(String.init) ?? entry
        return .unreadable(message: L10n.format("archive.error.itemMissing", "“%@” isn’t in the archive.", name))
    }
}

extension ArchiveExtractor {
    /// The error a failed file promise of the entry `name` completes with. The receiver (Finder) shows only its
    /// description, and the cause is often bsdtar's own untranslated text, so the cause goes inside a sentence
    /// naming the entry. The description is a plain user-info string, so it survives the trip to the receiver.
    public static func promiseError(name: String, _ error: any Error) -> NSError {
        let text = L10n.format("archive.promise.failed", "“%1$@” couldn’t be extracted: %2$@", name, error.localizedDescription)
        return NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
            userInfo: [NSLocalizedDescriptionKey: text])
    }
}
