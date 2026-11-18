import Foundation

/// Searches the Spotlight index with `NSMetadataQuery`: names under a folder, or a tag on this computer.
///
/// The query lives on the main actor (it needs a run loop); the result paths become `FileItem`s off the
/// main thread through `PathQueries.run`, in batches. Spotlight-only behavior is kept in thin glue; the
/// predicate and the result filter are pure and unit-tested.
public struct SpotlightSearch: FileSearchEngine {
    let limit: Int

    /// `limit` is the result cap (Ruling P6-3).
    public init(limit: Int = 10_000) {
        self.limit = limit
    }

    /// A folder query matches `kMDItemFSName` as a case- and diacritic-insensitive substring; a tag query
    /// matches a whole `kMDItemUserTags` value case-insensitively. Both values go through `likeEscaped`, so
    /// `*`, `?`, `\` and `'` match literally (MDQuery's `==` takes wildcards too, hence `LIKE` for tags).
    public static func predicate(for query: SearchQuery) -> NSPredicate {
        switch query.scope {
        case .folder:
            let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(SearchPattern.likeEscaped(text))*")
        case .tag(let name):
            return NSPredicate(format: "kMDItemUserTags LIKE[c] %@", SearchPattern.likeEscaped(name))
        }
    }

    /// The query's search scopes: the folder, or the whole local computer for a tag.
    static func searchScopes(for query: SearchQuery) -> [Any] {
        switch query.scope {
        case .folder(let url): [url]
        case .tag: [NSMetadataQueryLocalComputerScope]
        }
    }

    /// Drops the searched folder itself (Spotlight can return it; enumeration never does), unless
    /// `includeHidden` hidden items, and for a tag view the items whose freshly loaded tags no longer have
    /// `tag` (the index lags behind a tag just removed; compared case-insensitively, like `FileTag`).
    static func keep(_ items: [FileItem], root: URL?, tag: String? = nil, includeHidden: Bool) -> [FileItem] {
        let rootPath = root?.standardizedFileURL.path
        let wanted = tag.map { FileTag(name: $0, color: .none) }
        return items.filter { item in
            (includeHidden || !item.isHidden) && item.url.standardizedFileURL.path != rootPath
                && (wanted.map { item.tags.contains($0) } ?? true)
        }
    }

    public func search(_ query: SearchQuery, includeHidden: Bool) -> AsyncStream<SearchUpdate> {
        let limit = limit
        return AsyncStream(bufferingPolicy: SearchUpdate.bufferingPolicy) { continuation in
            let task = Task { @MainActor in
                await Self.run(query, includeHidden: includeHidden, limit: limit) { continuation.yield($0) }
                if !Task.isCancelled { continuation.yield(.finished) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum Event: Sendable { case progress, finished }

    /// Runs one query until it finishes gathering, emitting throttled snapshots and a final one (none when
    /// cancelled). Stops early, truncated, once more than `limit` items are found.
    @MainActor private static func run(
        _ query: SearchQuery, includeHidden: Bool, limit: Int, emit: (SearchUpdate) -> Void
    ) async {
        let metadataQuery = NSMetadataQuery()
        metadataQuery.predicate = predicate(for: query)
        metadataQuery.searchScopes = searchScopes(for: query)
        metadataQuery.notificationBatchingInterval = 0.2
        let root: URL? = if case .folder(let url) = query.scope { url } else { nil }
        let tag: String? = if case .tag(let name) = query.scope { name } else { nil }

        let (events, eventSink) = AsyncStream.makeStream(of: Event.self)
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: .NSMetadataQueryDidStartGathering, object: metadataQuery, queue: .main) {
                _ in eventSink.yield(.progress)
            },
            center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: metadataQuery, queue: .main) {
                _ in eventSink.yield(.progress)
            },
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: metadataQuery, queue: .main) {
                _ in
                eventSink.yield(.finished)
                eventSink.finish()
            },
        ]
        defer {
            metadataQuery.stop()
            observers.forEach(center.removeObserver)
        }
        guard metadataQuery.start() else {
            emit(.results([], truncated: false))
            return
        }

        var seen = Set<String>()
        var items: [FileItem] = []
        var throttle = SearchThrottle(interval: .milliseconds(200))
        var pending = false
        // Ends early (nil) when the task is cancelled.
        for await event in events {
            let paths = newPaths(of: metadataQuery, seen: &seen, max: limit + 1 - items.count)
            let loaded = await load(paths)
            if Task.isCancelled { return }
            items += keep(loaded, root: root, tag: tag, includeHidden: includeHidden)
            if items.count > limit {
                emit(.results(Array(items.prefix(limit)), truncated: true))
                return
            }
            pending = pending || !loaded.isEmpty
            if event == .finished { break }
            if pending, throttle.ready() {
                emit(.results(items, truncated: false))
                pending = false
            }
        }
        if Task.isCancelled { return }
        emit(.results(items, truncated: false))
    }

    /// Paths of results not seen before, at most `max`. Updates are paused while reading so the result
    /// list doesn't change underneath.
    @MainActor private static func newPaths(of query: NSMetadataQuery, seen: inout Set<String>, max: Int) -> [String] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var paths: [String] = []
        for index in 0..<query.resultCount where paths.count < max {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                seen.insert(path).inserted
            else { continue }
            paths.append(path)
        }
        return paths
    }

    /// Builds items for `paths` off the main thread, a batch per blocking call; vanished files are skipped.
    private static func load(_ paths: [String]) async -> [FileItem] {
        var items: [FileItem] = []
        for start in stride(from: 0, to: paths.count, by: 500) {
            let batch = Array(paths[start..<min(start + 500, paths.count)])
            items += await PathQueries.run {
                batch.compactMap { try? FileItem.load(URL(fileURLWithPath: $0)) }
            }
            if Task.isCancelled { break }
        }
        return items
    }
}
