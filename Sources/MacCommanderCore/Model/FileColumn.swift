import Foundation

public enum FileColumn: String, CaseIterable, Codable, Sendable {
    case name, dateModified, dateCreated, dateAdded, size, kind, tags
    /// The folder holding a search result; only shown while searching.
    case location

    public var title: String {
        switch self {
        case .name: L10n.string("fileList.column.name", "Name")
        case .dateModified: L10n.string("fileList.column.dateModified", "Date Modified")
        case .dateCreated: L10n.string("fileList.column.dateCreated", "Date Created")
        case .dateAdded: L10n.string("fileList.column.dateAdded", "Date Added")
        case .size: L10n.string("fileList.column.size", "Size")
        case .kind: L10n.string("fileList.column.kind", "Kind")
        case .tags: L10n.string("fileList.column.tags", "Tags")
        case .location: L10n.string("fileList.column.location", "Location")
        }
    }
}
