import Foundation

/// Searches a folder tree by walking it with `FileManager`. Used for network volumes and as the fallback
/// when Spotlight finds nothing (unindexed or excluded folders). Package contents are skipped; hidden
/// items only with `includeHidden`. A tag query finishes at once: tags need Spotlight.
public struct EnumerationSearch: FileSearchEngine {
    let limit: Int
    let interval: Duration

    /// `limit` is the result cap (Ruling P6-3).
    public init(limit: Int = 10_000) {
        self.init(limit: limit, interval: .milliseconds(200))
    }

    /// Test hook: `interval` is the minimum time between `.results` updates.
    init(limit: Int, interval: Duration) {
        self.limit = limit
        self.interval = interval
    }

    public func search(_ query: SearchQuery, includeHidden: Bool) -> AsyncStream<SearchUpdate> {
        AsyncStream(bufferingPolicy: SearchUpdate.bufferingPolicy) { continuation in
            guard case .folder(let root) = query.scope else {
                continuation.yield(.finished)
                continuation.finish()
                return
            }
            let (text, limit, interval) = (query.text, limit, interval)
            // The walk runs on its own thread: on a dead share it can block for minutes.
            let task = Task {
                await SerialQueueExecutor.withOwnThread(label: "MacCommander search") {
                    Self.walk(root, text: text, includeHidden: includeHidden, limit: limit, interval: interval) {
                        continuation.yield($0)
                    }
                }
                if !Task.isCancelled { continuation.yield(.finished) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Walks `root`, emitting throttled snapshots and a final one. Returns early when cancelled (without a
    /// final snapshot) or when a match beyond `limit` turns up (final snapshot truncated).
    private static func walk(
        _ root: URL, text: String, includeHidden: Bool, limit: Int, interval: Duration,
        emit: (SearchUpdate) -> Void
    ) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        var items: [FileItem] = []
        var throttle = SearchThrottle(interval: interval)
        var emitted = false, pending = false
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [], options: options, errorHandler: { _, _ in true })
        {
            // `nextObject()` rather than `for in`: NSEnumerator's iterator is unavailable in async contexts.
            while let next = enumerator.nextObject() {
                if Task.isCancelled { return }
                guard let url = next as? URL, SearchPattern.matches(url.lastPathComponent, text: text) else {
                    continue
                }
                guard items.count < limit else {
                    emit(.results(items, truncated: true))
                    return
                }
                guard let item = try? FileItem.load(url) else { continue }
                items.append(item)
                pending = true
                if throttle.ready() {
                    emit(.results(items, truncated: false))
                    emitted = true
                    pending = false
                }
            }
        }
        if Task.isCancelled { return }
        if pending || !emitted { emit(.results(items, truncated: false)) }
    }
}
