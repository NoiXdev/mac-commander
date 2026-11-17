import Foundation

public enum FileColumn: String, CaseIterable, Codable, Sendable {
    case name, dateModified, dateCreated, dateAdded, size, kind, tags

    public var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .dateModified: String(localized: "Date Modified")
        case .dateCreated: String(localized: "Date Created")
        case .dateAdded: String(localized: "Date Added")
        case .size: String(localized: "Size")
        case .kind: String(localized: "Kind")
        case .tags: String(localized: "Tags")
        }
    }
}
