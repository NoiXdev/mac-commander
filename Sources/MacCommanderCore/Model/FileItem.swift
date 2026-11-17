import Foundation

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

    /// Every resource key `load` reads, used for prefetching during directory enumeration.
    public static let resourceKeys: [URLResourceKey] = [
        .localizedNameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey,
        .localizedTypeDescriptionKey,
    ]

    public static func load(_ url: URL) throws -> FileItem {
        let values = try url.resourceValues(forKeys: Set(resourceKeys))
        let isPackage = values.isPackage ?? false
        let isDirectory = (values.isDirectory ?? false) && !isPackage
        return FileItem(
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
    }
}
