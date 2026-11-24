import Foundation

/// One row in the Settings window's sidebar, and the source of truth for that sidebar: `allCases` is the order
/// the rows appear in, and each case owns its title and SF Symbol. The detail column shows the matching pane.
public enum SettingsSection: String, CaseIterable, Hashable, Sendable {
    case general, view, openWith, terminal, shortcuts, sidebar, tags, network

    public var title: String {
        switch self {
        case .general: L10n.string("settings.section.general", "General")
        case .view: L10n.string("settings.section.view", "View")
        case .openWith: L10n.string("settings.section.openWith", "Open With")
        case .terminal: L10n.string("settings.section.terminal", "Terminal")
        case .shortcuts: L10n.string("settings.section.shortcuts", "Shortcuts")
        case .sidebar: L10n.string("settings.section.sidebar", "Sidebar")
        case .tags: L10n.string("settings.section.tags", "Tags")
        case .network: L10n.string("settings.section.network", "Network")
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .view: "eye"
        case .openWith: "doc.badge.gearshape"
        case .terminal: "terminal"
        case .shortcuts: "keyboard"
        case .sidebar: "sidebar.left"
        case .tags: "tag"
        case .network: "network"
        }
    }
}
