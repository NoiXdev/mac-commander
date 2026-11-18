import Foundation

public enum CloudStatus: Sendable, Hashable { case current, notDownloaded, downloading }

public struct FileItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: URL { url }
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let dateModified: Date?
    public let dateCreated: Date?
    public let dateAdded: Date?
    public let kind: String
    /// A symlink entry inside an archive (listed, not followed). Always false for real files.
    public internal(set) var isSymlink = false
    /// Finder tags with colors. Empty for untagged files and archive entries.
    public internal(set) var tags: [FileTag] = []
    /// iCloud state; nil for items that are not in iCloud Drive.
    public internal(set) var cloudStatus: CloudStatus? = nil

    /// The iCloud keys are deliberately not in `resourceKeys`: on macOS, requesting them in the same call
    /// makes `tagNames` come back nil. `load` reads them in a second call.
    /// Every resource key `load` reads, used for prefetching during directory enumeration.
    public static let resourceKeys: [URLResourceKey] = [
        .localizedNameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey,
        .localizedTypeDescriptionKey, .tagNamesKey,
    ]

    private static let cloudKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
    ]

    public static func load(_ url: URL) throws -> FileItem {
        let values = try url.resourceValues(forKeys: Set(resourceKeys))
        let isPackage = values.isPackage ?? false
        let isDirectory = (values.isDirectory ?? false) && !isPackage
        var item = FileItem(
            url: url,
            name: values.localizedName ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isHidden: values.isHidden ?? false,
            size: isDirectory ? nil : values.fileSize.map(Int64.init),
            dateModified: values.contentModificationDate,
            dateCreated: values.creationDate,
            dateAdded: values.addedToDirectoryDate,
            kind: values.localizedTypeDescription ?? "")
        // The xattr carries the colors; read it only for tagged files so untagged ones cost nothing.
        if let names = values.tagNames, !names.isEmpty {
            let read = TagStore.readNow(url)
            item.tags = read.isEmpty ? names.map { FileTag(name: $0, color: .none) } : read
        }
        if let cloud = try? url.resourceValues(forKeys: cloudKeys), cloud.isUbiquitousItem == true {
            if cloud.ubiquitousItemIsDownloading == true {
                item.cloudStatus = .downloading
            } else if cloud.ubiquitousItemDownloadingStatus == .current {
                item.cloudStatus = .current
            } else {
                item.cloudStatus = .notDownloaded
            }
        }
        return item
    }
}
