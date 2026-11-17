import Foundation

/// A location inside an archive: the archive file and the path within it.
public struct ArchiveLocation: Hashable, Sendable {
    public let archive: URL
    /// "" is the archive's root; otherwise no leading or trailing "/".
    public let inner: String

    public init(archive: URL, inner: String) {
        self.archive = archive.standardizedFileURL
        self.inner = inner
    }
}

/// Virtual archive paths: an archive's file URL followed by the inner path, e.g. `/a/b.zip/img/x.png`.
public enum ArchivePath {
    /// The archive location `url` points into: the first path component that is an existing regular file
    /// (symlinks resolved), with the rest as `inner`. nil for ordinary paths. Plain `stat`s only, cheap.
    /// The URL is used as given (no `/var` resolution), so `archive` keeps the caller's spelling.
    public static func split(_ url: URL) -> ArchiveLocation? {
        let components = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        var path = ""
        for (offset, component) in components.enumerated() {
            path += "/" + component
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            if info.st_mode & S_IFMT == S_IFLNK {
                guard stat(path, &info) == 0 else { return nil }
            }
            if info.st_mode & S_IFMT == S_IFREG {
                return ArchiveLocation(
                    archive: URL(fileURLWithPath: path, isDirectory: false),
                    inner: components[(offset + 1)...].joined(separator: "/"))
            }
        }
        return nil
    }

    /// The URL of `inner` ("" = the archive itself) inside `archive`.
    public static func url(archive: URL, inner: String) -> URL {
        inner.split(separator: "/").reduce(archive) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
    }

    /// The inner path of `url` inside `archive`, by path prefix only (no file-system access, cheap enough
    /// for building menus and actions on the main actor); nil for the archive itself or a URL outside it.
    public static func inner(of url: URL, in archive: URL) -> String? {
        let prefix = archive.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
