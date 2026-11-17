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

    /// `urls` without those lying inside another of them (compared by standardized path), in their order.
    /// A selection that holds a folder and rows of its inline-expanded contents acts on the folder alone.
    public static func topLevel(_ urls: [URL]) -> [URL] {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        return urls.filter { url in
            var ancestor = url.standardizedFileURL
            while ancestor.path != "/" {
                ancestor = ancestor.deletingLastPathComponent()
                if paths.contains(ancestor.path) { return false }
            }
            return true
        }
    }

    /// The URLs of `candidates` that are one of `changed`, compared by canonical path (symlinks resolved,
    /// standardized), in their order. Touches the file system to resolve symlinks: keep `candidates` small.
    public static func folders(_ candidates: [URL], matching changed: [URL]) -> [URL] {
        guard !changed.isEmpty else { return [] }
        func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let changedPaths = Set(changed.map(canonical))
        return candidates.filter { changedPaths.contains(canonical($0)) }
    }
}
