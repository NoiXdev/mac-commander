import Foundation
import UniformTypeIdentifiers

/// Why an archive couldn't be listed or extracted.
public enum ArchiveError: Error, Equatable, Sendable {
    case passwordRequired, incorrectPassword
    /// The calling task was cancelled; bsdtar was terminated.
    case cancelled
    /// bsdtar doesn't know the format ("Unrecognized archive format" / "not supported").
    case unsupported(message: String)
    /// Any other bsdtar failure.
    case unreadable(message: String)
}

/// Readable texts for receivers that only show `localizedDescription`, e.g. Finder after a failed file promise.
extension ArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passwordRequired: String(localized: "The archive is encrypted. Enter its password to extract it.")
        case .incorrectPassword: String(localized: "The password you entered is incorrect.")
        case .cancelled: String(localized: "The operation was cancelled.")
        case .unsupported(let message), .unreadable(let message): message
        }
    }
}

/// App-wide archive listings: runs `/usr/bin/bsdtar -tv` once per archive version and caches the index.
/// (Read mode, not `-c --format=mtree @archive`: bsdtar 3.5.3 hands `--passphrase` to the writer in
/// create mode and fails, and without it an archive with encrypted data prompts forever.)
/// Session passwords live here, in memory only.
public actor ArchiveCatalog {
    public static let shared = ArchiveCatalog()

    private struct CacheKey: Hashable {
        let path: String
        let size: Int64
        let modified: Date
    }

    private let bsdtar: URL
    private static let env = URL(fileURLWithPath: "/usr/bin/env")
    /// Most recently used last; at most `cacheLimit` entries.
    private var cache: [(key: CacheKey, index: ArchiveIndex)] = []
    private let cacheLimit = 8
    private var passwords: [String: String] = [:]
    /// Number of bsdtar listings started, for tests.
    private(set) var runCount = 0
    /// Test hook: thrown by `index(of:)` for archives without a session password.
    private let testError: ArchiveError?

    public init(bsdtar: URL = URL(fileURLWithPath: "/usr/bin/bsdtar")) {
        self.bsdtar = bsdtar
        testError = nil
    }

    /// Test hook: listings fail with `testError` until a password is set for the archive
    /// (e.g. `.passwordRequired`, which a real zip only reports for encrypted headers).
    init(testError: ArchiveError) {
        bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
        self.testError = testError
    }

    /// The archive's (path, size, mtime), stat'ed off the actor (`PathQueries.run`).
    private static func cacheKey(of path: String) async throws(ArchiveError) -> CacheKey {
        let result: Result<CacheKey, ArchiveError> = await PathQueries.run {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                return .success(CacheKey(
                    path: path,
                    size: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
                    modified: attributes[.modificationDate] as? Date ?? .distantPast))
            } catch {
                return .failure(.unreadable(message: error.localizedDescription))
            }
        }
        return try result.get()
    }

    /// Index for `archive`, listed once per (path, size, mtime). Uses the session password if one is set.
    /// Cancelling the calling task terminates bsdtar and throws `.cancelled`.
    public func index(of archive: URL) async throws(ArchiveError) -> ArchiveIndex {
        let path = Self.path(of: archive)
        if let testError, passwords[path] == nil { throw testError }
        // A single stat, on the blocking-I/O queue: the archive may be on a network volume, and a stat that
        // hangs there must not hold this app-wide actor (every archive window waits on it). The cache is read
        // only after the await.
        let key = try await Self.cacheKey(of: path)
        if let position = cache.firstIndex(where: { $0.key == key }) {
            let hit = cache.remove(at: position)
            cache.append(hit)
            return hit.index
        }

        let password = passwords[path]
        runCount += 1
        let output: ProcessOutput
        do {
            // C locale + UTC: English month names, `\ooo` escapes for non-ASCII, UTC dates.
            output = try await ProcessRunner.run(Self.env, [
                "LC_ALL=C", "TZ=UTC", bsdtar.path, "-tvf", path,
                // Always pass a passphrase: without one bsdtar prompts "Enter passphrase:" forever.
                "--passphrase", password ?? UUID().uuidString,
            ])
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .unreadable(message: error.localizedDescription)
        }
        if output.status != 0 {
            throw Self.error(stderr: output.stderr, hadPassword: password != nil)
        }
        let index = ArchiveIndex(listing: String(decoding: output.stdout, as: UTF8.self))

        cache.removeAll { $0.key.path == path }
        cache.append((key, index))
        if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
        return index
    }

    /// FileItems of `folder` ("" = root) inside `archive`. Names starting with "." and anything in a
    /// `__MACOSX` folder are hidden, and left out unless `includeHidden`.
    public func items(
        in folder: String, of archive: URL, includeHidden: Bool
    ) async throws(ArchiveError) -> [FileItem] {
        let index = try await index(of: archive)
        guard let entries = index.entries(in: folder) else {
            throw .unreadable(message: String(localized: "The folder “\(folder)” isn’t in the archive."))
        }
        return entries.compactMap { entry in
            let components = entry.path.split(separator: "/").map(String.init)
            let name = components.last ?? entry.path
            let isHidden = name.hasPrefix(".") || components.contains("__MACOSX")
            if isHidden && !includeHidden { return nil }
            let url = ArchivePath.url(archive: archive, inner: entry.path)
            return FileItem(
                url: url,
                name: name,
                isDirectory: entry.isDirectory,
                isPackage: false,
                isHidden: isHidden,
                size: entry.isDirectory ? nil : entry.size,
                dateModified: entry.modified,
                dateCreated: nil,
                dateAdded: nil,
                kind: Self.kind(name: name, isDirectory: entry.isDirectory),
                isSymlink: entry.isSymlink)
        }
    }

    /// Remembers `password` for `archive` for the rest of the app session (memory only).
    public func setPassword(_ password: String, for archive: URL) {
        passwords[Self.path(of: archive)] = password
    }

    public func password(for archive: URL) -> String? {
        passwords[Self.path(of: archive)]
    }

    /// Drops the cached index of `archive`, so the next request lists it again.
    public func invalidate(_ archive: URL) {
        let path = Self.path(of: archive)
        cache.removeAll { $0.key.path == path }
    }

    // MARK: Helpers

    private static func path(of archive: URL) -> String {
        archive.standardizedFileURL.path
    }

    /// Maps bsdtar's stderr after a failed listing to an `ArchiveError`. A failed checksum with a password counts
    /// as an incorrect password: classic zip encryption lets about one wrong password in 256 through its check,
    /// and the entry's CRC then fails. (A password is only known for an archive that asked for one.)
    static func error(stderr: String, hadPassword: Bool) -> ArchiveError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.range(of: "passphrase", options: .caseInsensitive) != nil {
            return hadPassword ? .incorrectPassword : .passwordRequired
        }
        if hadPassword && isChecksumFailure(message) { return .incorrectPassword }
        if message.contains("Unrecognized archive format") || message.contains("not supported") {
            return .unsupported(message: message)
        }
        return .unreadable(message: message)
    }

    /// Whether bsdtar reported an entry whose data failed its CRC check.
    static func isChecksumFailure(_ stderr: String) -> Bool {
        stderr.contains("bad CRC")
    }

    private static func kind(name: String, isDirectory: Bool) -> String {
        if isDirectory { return String(localized: "Folder") }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let description = UTType(filenameExtension: ext)?.localizedDescription {
            return description
        }
        return String(localized: "Document")
    }
}
