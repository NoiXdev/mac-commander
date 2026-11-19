import Foundation

/// One window to open for URLs handed to the app: show `folder`, with `selection` selected in it.
public struct OpenRequest: Equatable, Sendable {
    public let folder: URL
    public let selection: [URL]

    public init(folder: URL, selection: [URL]) {
        self.folder = folder
        self.selection = selection
    }

    /// Groups incoming URLs into windows. Non-file URLs are dropped. Exactly one folder opens itself;
    /// otherwise the URLs group by parent folder (in order of first appearance) and are selected there.
    public static func requests(for urls: [URL], isFolder: (URL) -> Bool) -> [OpenRequest] {
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        if files.count == 1, let only = files.first, isFolder(only) {
            return [OpenRequest(folder: only, selection: [])]
        }
        var parents: [URL] = []
        var groups: [String: [URL]] = [:]
        for url in files {
            let parent = URL(fileURLWithPath: url.deletingLastPathComponent().path)
            if groups[parent.path] == nil { parents.append(parent) }
            if !(groups[parent.path] ?? []).contains(url) { groups[parent.path, default: []].append(url) }
        }
        return parents.map { OpenRequest(folder: $0, selection: groups[$0.path] ?? []) }
    }

    /// Whether `url` is a real directory that isn't a package; symlinks are followed (`/tmp` is a folder). May
    /// block: run it off the main actor.
    public static func folderCheck(_ url: URL) -> Bool {
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}
