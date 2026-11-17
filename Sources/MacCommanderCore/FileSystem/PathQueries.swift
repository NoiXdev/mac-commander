import Foundation

/// What one look at a path found. Symlinks are followed (a symlink to a folder is a folder).
public struct PathInfo: Sendable, Equatable {
    public let exists: Bool
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isRegularFile: Bool
    /// False for network volumes. A missing path reports true: there is no volume to ask, and
    /// the caller treats it as gone anyway.
    public let isLocalVolume: Bool

    public init(exists: Bool, isDirectory: Bool, isPackage: Bool, isRegularFile: Bool, isLocalVolume: Bool) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isRegularFile = isRegularFile
        self.isLocalVolume = isLocalVolume
    }

    public static let missing = PathInfo(
        exists: false, isDirectory: false, isPackage: false, isRegularFile: false, isLocalVolume: true)
}

/// File-system questions the UI and the browser model ask about single paths, always answered off the
/// main actor: any path may be on a network volume, where a `stat` can block for as long as the server
/// takes to time out. None of these time out themselves; a hung call only holds a background thread.
public enum PathQueries {
    /// One `stat` (plus a `resourceValues` call for package and volume flags when the path exists).
    @concurrent
    public static func info(_ url: URL) async -> PathInfo {
        infoNow(url)
    }

    /// `ArchivePath.split` off the main actor.
    @concurrent
    public static func archiveLocation(_ url: URL) async -> ArchiveLocation? {
        ArchivePath.split(url)
    }

    /// `PathUtilities.nearestExistingAncestor` off the main actor.
    @concurrent
    public static func nearestExistingFolder(_ url: URL) async -> URL {
        PathUtilities.nearestExistingAncestor(of: url)
    }

    /// The path with every symlink resolved (`realpath`, so `/var/x` gives `/private/var/x`), for comparing
    /// two spellings of one folder. A path that can't be resolved comes back standardized.
    @concurrent
    public static func canonicalPath(_ url: URL) async -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `url` with its symlinks resolved when the item itself is a symlink; otherwise `url` as given.
    @concurrent
    public static func resolvingSymlink(_ url: URL) async -> URL {
        let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        return isSymlink ? url.resolvingSymlinksInPath() : url
    }

    /// Whether anything is at `url`, without following a final symlink (a broken symlink exists).
    @concurrent
    public static func entryExists(_ url: URL) async -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The name Finder shows (localized, e.g. "Schreibtisch" for `~/Desktop`); the last path component when
    /// the item can't be asked.
    @concurrent
    public static func displayName(_ url: URL) async -> String {
        if let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName { return name }
        return url.path == "/" ? FileManager.default.displayName(atPath: "/") : url.lastPathComponent
    }

    /// The synchronous body of `info`, for callers already off the main actor.
    public static func infoNow(_ url: URL) -> PathInfo {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return .missing }
        let type = info.st_mode & S_IFMT
        let isDirectory = type == S_IFDIR
        // Package and volume flags describe the target, so resolve a symlink first (lstat is cheap
        // next to the stat above, which already reached the target).
        var link = stat()
        let target = lstat(url.path, &link) == 0 && link.st_mode & S_IFMT == S_IFLNK
            ? url.resolvingSymlinksInPath() : url
        let values = try? target.resourceValues(forKeys: [.isPackageKey, .volumeIsLocalKey])
        return PathInfo(
            exists: true,
            isDirectory: isDirectory,
            isPackage: isDirectory && values?.isPackage == true,
            isRegularFile: type == S_IFREG,
            isLocalVolume: values?.volumeIsLocal ?? true)
    }
}

/// The path queries `BrowserModel` uses; a test hook so tests can slow them down. The default forwards to
/// `PathQueries`. Implementations must not run on the caller's actor.
protocol PathQueriesProvider: Sendable {
    func info(_ url: URL) async -> PathInfo
    func archiveLocation(_ url: URL) async -> ArchiveLocation?
    func nearestExistingFolder(_ url: URL) async -> URL
    func canonicalPath(_ url: URL) async -> String
    func resolvingSymlink(_ url: URL) async -> URL
    func entryExists(_ url: URL) async -> Bool
}

struct LivePathQueries: PathQueriesProvider {
    func info(_ url: URL) async -> PathInfo { await PathQueries.info(url) }
    func archiveLocation(_ url: URL) async -> ArchiveLocation? { await PathQueries.archiveLocation(url) }
    func nearestExistingFolder(_ url: URL) async -> URL { await PathQueries.nearestExistingFolder(url) }
    func canonicalPath(_ url: URL) async -> String { await PathQueries.canonicalPath(url) }
    func resolvingSymlink(_ url: URL) async -> URL { await PathQueries.resolvingSymlink(url) }
    func entryExists(_ url: URL) async -> Bool { await PathQueries.entryExists(url) }
}
