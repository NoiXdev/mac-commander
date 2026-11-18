import Foundation

/// Finder's tag color numbers, as stored in the tag xattr.
public enum TagColor: Int, CaseIterable, Codable, Sendable {
    case none = 0, gray, green, purple, blue, yellow, red, orange

    /// The order Finder lists the colors in.
    public static let finderOrder: [TagColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
}

/// A Finder tag. Equality and hashing go by name only, compared case-insensitively (as Finder does).
public struct FileTag: Hashable, Codable, Sendable {
    public let name: String
    /// The color number exactly as stored. Unknown numbers are kept so a rewrite doesn't alter them.
    let rawColor: Int

    public var color: TagColor { TagColor(rawValue: rawColor) ?? .none }

    public init(name: String, color: TagColor) {
        self.name = name
        self.rawColor = color.rawValue
    }

    init(name: String, rawColor: Int) {
        self.name = name
        self.rawColor = rawColor
    }

    public static func == (lhs: FileTag, rhs: FileTag) -> Bool {
        lhs.name.lowercased() == rhs.name.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name.lowercased())
    }
}
