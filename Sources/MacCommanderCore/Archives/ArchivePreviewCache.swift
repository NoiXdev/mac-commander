import Foundation

/// Temporary copies of archive entries for Quick Look and Open: the system can only preview or open real
/// files, never the virtual paths inside an archive. Files are extracted per entry, once per archive version,
/// and stay until `purge` (at launch and at quit) or until the archive changes.
///
/// Layout: `root/<UUID>/` is one archive version, keyed by the archive's standardized path, size and mtime.
/// Each extraction run stages its missing entries into its own `ArchiveExtractor` staging folder inside the
/// version folder (`root/<UUID>/.mc-partial-<UUID>/<entry>`); the staged files are used in place and never
/// moved. Changes to an opened copy are not written back: archives are read-only.
///
/// Only the cache's own folders are removed permanently: the version folder of a changed archive, and `root`
/// on `purge`.
public actor ArchivePreviewCache {
    public static let shared = ArchivePreviewCache()

    private struct VersionKey: Equatable {
        let size: Int64
        let modified: Date
    }

    /// One archive version: its folder and the extracted file of each entry.
    private struct Version {
        let key: VersionKey
        let folder: URL
        var files: [String: URL] = [:]
    }

    private let root: URL
    private let catalog: ArchiveCatalog
    /// By the archive's standardized path.
    private var versions: [String: Version] = [:]
    /// Number of extraction runs started, for tests.
    private(set) var runCount = 0

    /// `catalog` supplies the session password of an encrypted archive.
    public init(
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacCommander Previews", isDirectory: true),
        catalog: ArchiveCatalog = .shared
    ) {
        self.root = root
        self.catalog = catalog
    }

    /// Extracts `entries` (files only) of `archive` into `root/<UUID per archive version>/` once and returns
    /// the extracted file URLs in the same order. Re-extracts when the archive's size or mtime changed.
    /// Entries already extracted (and still on disk) don't run bsdtar; the missing ones are extracted in one run.
    /// Cancelling the calling task terminates bsdtar and throws `.cancelled`; so does a `purge` or an archive
    /// change while the run was in progress.
    public func files(_ entries: [String], of archive: URL) async throws(ArchiveError) -> [URL] {
        let path = archive.standardizedFileURL.path
        let wanted = entries.map(Self.normalized)
        // Single stats and small folder operations; the actor never runs on the main thread.
        let key = try Self.key(of: path)
        if let current = versions[path], current.key != key {
            Self.remove(current.folder)
            versions[path] = nil
        }
        var version: Version
        if let current = versions[path] {
            version = current
        } else {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw .unreadable(message: error.localizedDescription)
            }
            version = Version(key: key, folder: folder)
            versions[path] = version
        }

        var missing: [String] = []
        for entry in wanted where !missing.contains(entry) {
            if let file = version.files[entry], FileManager.default.fileExists(atPath: file.path) { continue }
            missing.append(entry)
        }
        if !missing.isEmpty {
            runCount += 1
            let password = await catalog.password(for: archive)
            let staging: URL
            do {
                staging = try await ArchiveExtractor.stage(
                    missing, from: URL(fileURLWithPath: path), near: version.folder, password: password).staging
            } catch let error as ArchiveError {
                throw error
            } catch is CancellationError {
                throw .cancelled
            } catch {
                throw .unreadable(message: error.localizedDescription)
            }
            // Purged, or the archive changed, while bsdtar ran: the version folder is gone or about to be.
            guard versions[path]?.folder == version.folder else {
                ArchiveExtractor.removeStaging(staging)
                throw .cancelled
            }
            version = versions[path] ?? version
            for entry in missing {
                // `stage` verified each entry exists at this path (reached through real folders only).
                version.files[entry] = staging.appendingPathComponent(entry, isDirectory: false)
            }
            versions[path] = version
        }
        return try wanted.map { entry throws(ArchiveError) in
            guard let file = version.files[entry] else {
                throw .unreadable(message: String(localized: "“\(entry)” isn’t in the archive."))
            }
            return file
        }
    }

    /// Permanently removes `root` with everything extracted, including leftovers of an earlier session.
    public func purge() {
        versions = [:]
        Self.remove(root)
    }

    // MARK: Helpers

    /// No leading, trailing or doubled "/", no "." components; matches `ArchivePath` inner paths.
    private static func normalized(_ entry: String) -> String {
        entry.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }

    private static func key(of path: String) throws(ArchiveError) -> VersionKey {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return VersionKey(
                size: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
                modified: attributes[.modificationDate] as? Date ?? .distantPast)
        } catch {
            throw .unreadable(message: error.localizedDescription)
        }
    }

    /// Removes one of the cache's own folders. Extracted folders may be read-only, so they are made
    /// owner-writable first (never through symlinks).
    private static func remove(_ folder: URL) {
        ArchiveExtractor.makeFoldersOwnerWritable(folder)
        try? FileManager.default.removeItem(at: folder)
    }
}
