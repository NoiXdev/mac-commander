import Darwin
import Foundation

/// Temporary copies of archive entries for Quick Look and Open: the system can only preview or open real
/// files, never the virtual paths inside an archive. Files are extracted per entry, once per archive version,
/// and stay until `purge` (at launch and at quit) or until the archive changes.
///
/// Layout: `root/<UUID>/` is one archive version, keyed by the archive's standardized path, size and mtime.
/// Each extraction run stages its missing entries into its own `ArchiveExtractor` staging folder inside the
/// version folder (`root/<UUID>/.mc-partial-<UUID>/<entry>`); the staged files are used in place and never
/// moved. Extracted files are made read-only (`a-w`), so an opened copy can't be edited in place and later
/// previews keep showing the archive's content; archives are read-only. Staging folders are made read-only
/// too, so no app can save anything into the cache (it is removed permanently).
///
/// A symlink entry is refused (`.unreadable`): previewing or opening it would follow it out of the cache,
/// e.g. to `~/.zshrc`.
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
        if let current = versions[path], current.key != key || !Self.isFolder(current.folder) {
            // Changed, or its folder is gone (a temp cleaner, another instance's purge): start fresh.
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
            // `stage` verified each entry exists at this path (reached through real folders only).
            let staged = missing.map { staging.appendingPathComponent($0, isDirectory: false) }
            if staged.contains(where: Self.isSymlink) {
                ArchiveExtractor.removeStaging(staging)
                throw .unreadable(message: String(localized: "It’s a link."))
            }
            for (entry, file) in zip(missing, staged) {
                Self.makeReadOnly(file)
                version.files[entry] = file
            }
            Self.makeFoldersReadOnly(staging)
            versions[path] = version
        }
        return try wanted.map { entry throws(ArchiveError) in
            guard let file = version.files[entry] else {
                let name = entry.split(separator: "/").last.map(String.init) ?? entry
                throw .unreadable(message: String(localized: "“\(name)” isn’t in the archive."))
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

    /// `lstat`: true for a symlink itself, never following it.
    private static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// Removes write permission (a-w) from a regular file, found with `lstat`, and makes it owner-readable
    /// (u+r), so an entry stored with mode 000 can still be previewed. Best effort.
    private static func makeReadOnly(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
        chmod(url.path, (info.st_mode | S_IRUSR) & 0o7777 & ~(S_IWUSR | S_IWGRP | S_IWOTH))
    }

    /// Removes write permission (a-w) from `folder` and every folder below it, found with `lstat` (symlinks
    /// are never followed). Apps save a duplicate of a locked file next to it, and Archive Utility expands a
    /// nested archive beside itself; the cache is deleted permanently, so nothing may land there. Saving
    /// fails instead and the app asks for another place. `remove` makes the folders writable again. Best effort.
    private static func makeFoldersReadOnly(_ folder: URL) {
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names { makeFoldersReadOnly(folder.appendingPathComponent(name)) }
        }
        chmod(folder.path, info.st_mode & 0o7777 & ~(S_IWUSR | S_IWGRP | S_IWOTH))
    }

    /// `lstat`: true for a real folder (not a symlink to one).
    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
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
