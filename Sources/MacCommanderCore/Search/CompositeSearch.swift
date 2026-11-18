import Foundation

/// Picks the engine per Ruling P6-2: a folder on a local volume goes to Spotlight, falling back to
/// enumeration when Spotlight finishes with no results (unindexed or excluded folders); a folder on any
/// other volume goes to enumeration; a tag goes to Spotlight.
public struct CompositeSearch: FileSearchEngine {
    let spotlight: any FileSearchEngine
    let enumeration: any FileSearchEngine
    let isLocal: @Sendable (URL) async -> Bool

    public init(
        spotlight: any FileSearchEngine = SpotlightSearch(),
        enumeration: any FileSearchEngine = EnumerationSearch(),
        isLocal: @escaping @Sendable (URL) async -> Bool = { await PathQueries.info($0).isLocalVolume }
    ) {
        self.spotlight = spotlight
        self.enumeration = enumeration
        self.isLocal = isLocal
    }

    public func search(_ query: SearchQuery, includeHidden: Bool) -> AsyncStream<SearchUpdate> {
        let engines = self
        return AsyncStream { continuation in
            // Cancelling this task ends the inner stream's iteration, which cancels the inner engine's work.
            let task = Task {
                await engines.run(query, includeHidden: includeHidden) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ query: SearchQuery, includeHidden: Bool, emit: (SearchUpdate) -> Void) async {
        switch query.scope {
        case .tag:
            for await update in spotlight.search(query, includeHidden: includeHidden) { emit(update) }
        case .folder(let url):
            guard await isLocal(url) else {
                for await update in enumeration.search(query, includeHidden: includeHidden) { emit(update) }
                return
            }
            // Empty Spotlight snapshots are held back so the list doesn't flash "no results" before a fallback.
            var found = false
            for await update in spotlight.search(query, includeHidden: includeHidden) {
                if case .results(let items, _) = update, !items.isEmpty { found = true }
                if found { emit(update) }
            }
            guard !found, !Task.isCancelled else { return }
            for await update in enumeration.search(query, includeHidden: includeHidden) { emit(update) }
        }
    }
}
