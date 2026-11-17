import Foundation

public struct FileSortOrder: Codable, Equatable, Sendable {
    public var column: FileColumn
    public var ascending: Bool
    public var foldersOnTop: Bool

    public static let `default` = FileSortOrder(column: .name, ascending: true, foldersOnTop: false)

    public init(column: FileColumn, ascending: Bool, foldersOnTop: Bool) {
        self.column = column
        self.ascending = ascending
        self.foldersOnTop = foldersOnTop
    }

    public func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if foldersOnTop, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            var result = compareByColumn(lhs, rhs)
            if result == .orderedSame {
                result = Self.compareNames(lhs, rhs)
            }
            if result != .orderedSame {
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            // Stable, direction-independent tie break (e.g. NFD vs NFC spellings of one name).
            return lhs.url.path < rhs.url.path
        }
    }

    private static func compareNames(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        // Normalize first: localizedStandardCompare alone orders NFD before NFC spellings.
        lhs.name.precomposedStringWithCanonicalMapping
            .localizedStandardCompare(rhs.name.precomposedStringWithCanonicalMapping)
    }

    private func compareByColumn(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        switch column {
        case .name: Self.compareNames(lhs, rhs)
        case .dateModified: Self.compare(lhs.dateModified ?? .distantPast, rhs.dateModified ?? .distantPast)
        case .dateCreated: Self.compare(lhs.dateCreated ?? .distantPast, rhs.dateCreated ?? .distantPast)
        case .dateAdded: Self.compare(lhs.dateAdded ?? .distantPast, rhs.dateAdded ?? .distantPast)
        case .size: Self.compare(lhs.size ?? 0, rhs.size ?? 0)
        case .kind: lhs.kind.localizedStandardCompare(rhs.kind)
        case .tags: .orderedSame
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }
}
