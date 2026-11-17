import Foundation

/// Back/forward history for one pane. URLs are compared by their standardized file URL.
public struct NavigationHistory: Equatable, Sendable {
    public private(set) var current: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    public init(start: URL) {
        current = start
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Navigates to `url`, clearing the forward stack. Visiting the current location is a no-op.
    public mutating func visit(_ url: URL) {
        guard url.standardizedFileURL != current.standardizedFileURL else { return }
        backStack.append(current)
        current = url
        forwardStack.removeAll()
    }

    public mutating func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return previous
    }

    public mutating func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return next
    }

    /// Replaces the current location without touching the back/forward stacks.
    public mutating func replaceCurrent(with url: URL) {
        current = url
    }

    /// Moves every entry (current, back and forward) at or below `old` to the same place below `new`, by
    /// standardized path; other entries are kept. For a share that came back under another mount point name
    /// (`/Volumes/Media` → `/Volumes/Media-1`). No file-system access.
    public mutating func rewritePrefix(from old: URL, to new: URL) {
        let oldRoot = old.standardizedFileURL.path
        let newRoot = new.standardizedFileURL.path
        guard oldRoot != newRoot else { return }
        let oldPrefix = oldRoot.hasSuffix("/") ? oldRoot : oldRoot + "/"
        func rewrite(_ url: URL) -> URL {
            let path = url.standardizedFileURL.path
            if path == oldRoot { return URL(fileURLWithPath: newRoot, isDirectory: true) }
            guard path.hasPrefix(oldPrefix) else { return url }
            let rest = String(path.dropFirst(oldPrefix.count))
            return URL(fileURLWithPath: newRoot, isDirectory: true).appendingPathComponent(rest)
        }
        current = rewrite(current)
        backStack = backStack.map(rewrite)
        forwardStack = forwardStack.map(rewrite)
    }
}
