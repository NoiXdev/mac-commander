import Foundation
import Observation

public enum SidebarSection: String, CaseIterable, Codable, Sendable {
    case favorites, iCloud, locations, network, tags
}

public struct Preferences: Codable, Equatable, Sendable {
    /// The language's default name for a new file ("untitled.txt", "Neue Datei.txt", …).
    public static var builtInNewFileName: String { L10n.string("name.newFile", "untitled.txt") }

    /// What the user typed in Settings. Empty means the built-in name, which follows the language.
    public var newFileName = ""
    /// nil means the home folder.
    public var newWindowFolderPath: String?
    public var hiddenSidebarSections: Set<SidebarSection> = []
    /// Tag names removed from the sidebar's Tags section (still offered in menus). Compare case-insensitively.
    public var hiddenTags: Set<String> = []
    public var didShowFullDiskAccessHint = false
    /// The app for "Open in Terminal"; nil means no choice yet (see `TerminalApp.effective`).
    public var terminalApp: TerminalApp?
    /// Whether windows may show a second folder pane (View ▸ Dual Pane).
    public var dualPaneEnabled = false
    /// System-wide hotkey that brings MacCommander forward; nil means none.
    public var globalShortcut: GlobalShortcut?
    /// Tags set or created in-app, with their colors (Spotlight knows tag names only). See `TagCatalog`.
    public var knownTags: [FileTag] = []
    /// Per-extension apps for opening files inside MacCommander; the system's own association stays untouched.
    public var openWithRules = OpenWithRules()
    /// Whether MacCommander checks GitHub for a newer release once a day.
    public var updateCheckEnabled = true
    /// When the last update check was attempted (successful or not); nil means never.
    public var lastUpdateCheck: Date?

    public init(
        newFileName: String = "", newWindowFolderPath: String? = nil,
        hiddenSidebarSections: Set<SidebarSection> = [], hiddenTags: Set<String> = [],
        didShowFullDiskAccessHint: Bool = false, dualPaneEnabled: Bool = false
    ) {
        self.newFileName = newFileName
        self.newWindowFolderPath = newWindowFolderPath
        self.hiddenSidebarSections = hiddenSidebarSections
        self.hiddenTags = hiddenTags
        self.didShowFullDiskAccessHint = didShowFullDiskAccessHint
        self.dualPaneEnabled = dualPaneEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case newFileName, newWindowFolderPath, hiddenSidebarSections, hiddenTags, didShowFullDiskAccessHint
        case dualPaneEnabled, terminalApp, globalShortcut, knownTags
        case openWithRules, updateCheckEnabled, lastUpdateCheck
    }

    /// Lenient decoding: a missing or unreadable field falls back to its default only.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        newFileName = (try? c.decodeIfPresent(String.self, forKey: .newFileName)) ?? d.newFileName
        // Older versions stored the English default; it now means "use the built-in name".
        if newFileName == "untitled.txt" { newFileName = "" }
        newWindowFolderPath = try? c.decodeIfPresent(String.self, forKey: .newWindowFolderPath)
        didShowFullDiskAccessHint =
            (try? c.decodeIfPresent(Bool.self, forKey: .didShowFullDiskAccessHint)) ?? d.didShowFullDiskAccessHint
        dualPaneEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .dualPaneEnabled)) ?? d.dualPaneEnabled
        // An unknown app name (say from a newer version) means no choice.
        terminalApp = try? c.decodeIfPresent(TerminalApp.self, forKey: .terminalApp)
        globalShortcut = try? c.decodeIfPresent(GlobalShortcut.self, forKey: .globalShortcut)
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
        // Unreadable entries are dropped, the rest kept.
        var known: [FileTag] = []
        if var raw = try? c.nestedUnkeyedContainer(forKey: .knownTags) {
            while !raw.isAtEnd {
                if let tag = try? raw.decode(FileTag.self) {
                    known.append(tag)
                } else {
                    _ = try? raw.decode(AnyDecodable.self)
                }
            }
        }
        knownTags = known
        openWithRules = (try? c.decodeIfPresent(OpenWithRules.self, forKey: .openWithRules)) ?? d.openWithRules
        updateCheckEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .updateCheckEnabled)) ?? d.updateCheckEnabled
        lastUpdateCheck = try? c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
    }

    private struct AnyDecodable: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public static func isValidFileName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return false }
        return !name.contains("/") && !name.contains(":")
    }

    /// `newFileName` when valid, else the built-in name of the current language.
    public var effectiveNewFileName: String {
        Self.isValidFileName(newFileName) ? newFileName : Self.builtInNewFileName
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
