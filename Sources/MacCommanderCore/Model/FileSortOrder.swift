import Foundation

public struct FileSortOrder: Codable, Equatable, Sendable {
    public var column: FileColumn
    public var ascending: Bool
    public var foldersOnTop: Bool

    public static let `default` = FileSortOrder(column: .name, ascending: true, foldersOnTop: false)

    /// Lenient decoding: a missing or unreadable field falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        column = (try? c.decodeIfPresent(FileColumn.self, forKey: .column)) ?? d.column
        ascending = (try? c.decodeIfPresent(Bool.self, forKey: .ascending)) ?? d.ascending
        foldersOnTop = (try? c.decodeIfPresent(Bool.self, forKey: .foldersOnTop)) ?? d.foldersOnTop
    }

    private enum CodingKeys: String, CodingKey { case column, ascending, foldersOnTop }

    public init(column: FileColumn, ascending: Bool, foldersOnTop: Bool) {
        self.column = column
        self.ascending = ascending
        self.foldersOnTop = foldersOnTop
    }

    public func sorted(_ items: [FileItem]) -> [FileItem] {
        // Decorate once: normalizing names inside the comparator allocates per comparison.
        let decorated = items.map { (item: $0, key: Self.normalizedKey($0.name)) }
        return decorated.sorted { lhs, rhs in
            if foldersOnTop, lhs.item.isDirectory != rhs.item.isDirectory {
                return lhs.item.isDirectory
            }
            var result = compareByColumn(lhs.item, rhs.item, lhs.key, rhs.key)
            if result == .orderedSame {
                result = lhs.key.localizedStandardCompare(rhs.key)
            }
            if result != .orderedSame {
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            // Stable, direction-independent tie break (e.g. NFD vs NFC spellings of one name).
            return lhs.item.url.path < rhs.item.url.path
        }.map(\.item)
    }

    /// localizedStandardCompare alone orders NFD before NFC spellings, so normalize first.
    private static func normalizedKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    private func compareByColumn(
        _ lhs: FileItem, _ rhs: FileItem, _ lhsKey: String, _ rhsKey: String
    ) -> ComparisonResult {
        switch column {
        case .name: lhsKey.localizedStandardCompare(rhsKey)
        case .dateModified: Self.compare(lhs.dateModified ?? .distantPast, rhs.dateModified ?? .distantPast)
        case .dateCreated: Self.compare(lhs.dateCreated ?? .distantPast, rhs.dateCreated ?? .distantPast)
        case .dateAdded: Self.compare(lhs.dateAdded ?? .distantPast, rhs.dateAdded ?? .distantPast)
        case .size: Self.compare(lhs.size ?? 0, rhs.size ?? 0)
        case .kind: lhs.kind.localizedStandardCompare(rhs.kind)
        case .tags: Self.compareTags(lhs.tags, rhs.tags)
        }
    }

    /// Joined names, localized-standard order; untagged items sort after tagged ones.
    private static func compareTags(_ lhs: [FileTag], _ rhs: [FileTag]) -> ComparisonResult {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false):
            return lhs.map(\.name).joined(separator: ", ")
                .localizedStandardCompare(rhs.map(\.name).joined(separator: ", "))
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }
}
