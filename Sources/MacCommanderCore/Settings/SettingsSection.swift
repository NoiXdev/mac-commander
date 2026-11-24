import Foundation

/// One row in the Settings window's sidebar, and the source of truth for that sidebar: `allCases` is the order
/// the rows appear in, and each case owns its title and SF Symbol. The detail column shows the matching pane.
public enum SettingsSection: String, CaseIterable, Hashable, Sendable {
    case general, view, terminal, shortcuts, sidebar, tags, network

    public var title: String {
        switch self {
        case .general: String(localized: "General")
        case .view: String(localized: "View")
        case .terminal: String(localized: "Terminal")
        case .shortcuts: String(localized: "Shortcuts")
        case .sidebar: String(localized: "Sidebar")
        case .tags: String(localized: "Tags")
        case .network: String(localized: "Network")
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .view: "eye"
        case .terminal: "terminal"
        case .shortcuts: "keyboard"
        case .sidebar: "sidebar.left"
        case .tags: "tag"
        case .network: "network"
        }
    }
}
