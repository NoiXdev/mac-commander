import Foundation

/// Where a search looks: a folder and its subfolders, or every file on this computer with a tag.
public enum SearchScope: Hashable, Sendable {
    case folder(URL)
    case tag(String)
}

public struct SearchQuery: Hashable, Sendable {
    /// The name text to look for; ignored for `.tag`.
    public var text: String
    public var scope: SearchScope

    public init(text: String, scope: SearchScope) {
        self.text = text
        self.scope = scope
    }
}

public enum SearchUpdate: Sendable, Equatable {
    /// Every result so far (a full snapshot, not a delta). `truncated` means the result cap was hit and the
    /// search stopped there.
    case results([FileItem], truncated: Bool)
    /// The search is done; nothing follows.
    case finished
}

extension SearchUpdate {
    /// Engines' streams keep only the two newest updates: snapshots are full lists (up to 10,000 items), so
    /// a slow consumer skips stale ones instead of buffering them all. Every engine ends with its final
    /// `.results` directly followed by `.finished`, so those two are never dropped.
    static let bufferingPolicy = AsyncStream<SearchUpdate>.Continuation.BufferingPolicy.bufferingNewest(2)
}

/// A name search. The stream emits `.results` at most every 200 ms plus once at the end, then `.finished`.
/// Ending the iteration (or cancelling the task that iterates) stops the work.
public protocol FileSearchEngine: Sendable {
    func search(_ query: SearchQuery, includeHidden: Bool) -> AsyncStream<SearchUpdate>
}

/// Spaces `.results` updates: `ready()` is true at most once per `interval`.
struct SearchThrottle {
    let interval: Duration
    private var last = ContinuousClock.now

    init(interval: Duration) {
        self.interval = interval
    }

    mutating func ready() -> Bool {
        let now = ContinuousClock.now
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}
