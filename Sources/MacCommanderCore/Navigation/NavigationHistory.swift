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
}
