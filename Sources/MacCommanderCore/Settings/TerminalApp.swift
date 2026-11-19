import Foundation

/// The terminal "Open in Terminal" uses (Settings ▸ General). The folder is handed to the app as a document,
/// which both apps answer with a new shell in that folder.
public enum TerminalApp: String, Codable, CaseIterable, Sendable {
    case terminal, iTerm

    public var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        }
    }

    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        }
    }

    /// The app to use: the chosen one while it's installed; without a choice iTerm when installed; else Terminal.
    public static func effective(chosen: TerminalApp?, isInstalled: (TerminalApp) -> Bool) -> TerminalApp {
        if let chosen, isInstalled(chosen) { return chosen }
        if chosen == nil, isInstalled(.iTerm) { return .iTerm }
        return .terminal
    }

    /// The folders to open for `items`, without file-system access: a folder opens itself, anything else
    /// (files, packages) its parent. Each folder once, in the items' order.
    public static func folders(for items: [FileItem]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for item in items {
            let folder = item.isDirectory ? item.url : item.url.deletingLastPathComponent()
            let path = folder.standardizedFileURL.path
            if seen.insert(path).inserted { result.append(folder.standardizedFileURL) }
        }
        return result
    }
}
