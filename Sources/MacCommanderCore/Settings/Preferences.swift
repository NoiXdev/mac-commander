import Foundation
import Observation

public enum SidebarSection: String, CaseIterable, Codable, Sendable {
    case favorites, iCloud, locations, network, tags
}

public struct Preferences: Codable, Equatable, Sendable {
    public static let defaultNewFileName = "untitled.txt"

    public var newFileName = Preferences.defaultNewFileName
    /// nil means the home folder.
    public var newWindowFolderPath: String?
    public var hiddenSidebarSections: Set<SidebarSection> = []
    /// Tag names removed from the sidebar's Tags section (still offered in menus). Compare case-insensitively.
    public var hiddenTags: Set<String> = []
    public var didShowFullDiskAccessHint = false

    public init(
        newFileName: String = Preferences.defaultNewFileName, newWindowFolderPath: String? = nil,
        hiddenSidebarSections: Set<SidebarSection> = [], hiddenTags: Set<String> = [],
        didShowFullDiskAccessHint: Bool = false
    ) {
        self.newFileName = newFileName
        self.newWindowFolderPath = newWindowFolderPath
        self.hiddenSidebarSections = hiddenSidebarSections
        self.hiddenTags = hiddenTags
        self.didShowFullDiskAccessHint = didShowFullDiskAccessHint
    }

    private enum CodingKeys: String, CodingKey {
        case newFileName, newWindowFolderPath, hiddenSidebarSections, hiddenTags, didShowFullDiskAccessHint
    }

    /// Lenient decoding: a missing or unreadable field falls back to its default only.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        newFileName = (try? c.decodeIfPresent(String.self, forKey: .newFileName)) ?? d.newFileName
        newWindowFolderPath = try? c.decodeIfPresent(String.self, forKey: .newWindowFolderPath)
        didShowFullDiskAccessHint =
            (try? c.decodeIfPresent(Bool.self, forKey: .didShowFullDiskAccessHint)) ?? d.didShowFullDiskAccessHint
        // Unknown section names are dropped, the rest kept.
        var sections: Set<SidebarSection> = []
        if var raw = try? c.nestedUnkeyedContainer(forKey: .hiddenSidebarSections) {
            while !raw.isAtEnd {
                if let section = try? raw.decode(SidebarSection.self) {
                    sections.insert(section)
                } else {
                    _ = try? raw.decode(AnyDecodable.self)
                }
            }
        }
        hiddenSidebarSections = sections
        // Non-string entries are dropped, the rest kept.
        var tags: Set<String> = []
        if var raw = try? c.nestedUnkeyedContainer(forKey: .hiddenTags) {
            while !raw.isAtEnd {
                if let tag = try? raw.decode(String.self) {
                    tags.insert(tag)
                } else {
                    _ = try? raw.decode(AnyDecodable.self)
                }
            }
        }
        hiddenTags = tags
    }

    private struct AnyDecodable: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public static func isValidFileName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return false }
        return !name.contains("/") && !name.contains(":")
    }

    /// `newFileName` when valid, else `untitled.txt`.
    public var effectiveNewFileName: String {
        Self.isValidFileName(newFileName) ? newFileName : Self.defaultNewFileName
    }

    /// The chosen folder when set and existing, else home. `exists` may block (network volumes): call off main.
    public func newWindowFolder(exists: (URL) -> Bool) -> URL {
        if let path = newWindowFolderPath, path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if exists(url) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

@MainActor @Observable
public final class PreferencesStore {
    static let key = "preferences.v1"

    @ObservationIgnored private let defaults: UserDefaults

    public var preferences: Preferences {
        didSet { persist() }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        {
            preferences = decoded
        } else {
            // Missing or undecodable: use defaults without touching the stored value.
            preferences = Preferences()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
