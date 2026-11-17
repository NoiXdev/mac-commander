import Foundation

public enum PathUtilities {
    /// Returns `url` if it exists, otherwise the closest ancestor that does (at worst `/`).
    public static func nearestExistingAncestor(of url: URL, fileManager: FileManager = .default) -> URL {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            candidate = candidate.deletingLastPathComponent().standardizedFileURL
        }
        return URL(fileURLWithPath: "/")
    }

    /// Breadcrumb URLs from the root down to `url`, e.g. `[/, /Users, /Users/d]`.
    public static func segments(of url: URL) -> [URL] {
        var result = [URL(fileURLWithPath: "/")]
        var path = ""
        for component in url.standardizedFileURL.pathComponents where component != "/" {
            path += "/" + component
            result.append(URL(fileURLWithPath: path))
        }
        return result
    }
}
