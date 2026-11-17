import Foundation

public final class DirectoryWatcher: @unchecked Sendable {
    // @unchecked Sendable is safe because all mutable state (`isCancelled`,
    // `pending`) is only touched while holding `lock`; `source` and `queue`
    // are immutable after init and themselves thread-safe.
    private let lock = NSLock()
    private var isCancelled = false
    private var pending: DispatchWorkItem?
    private var firstUnfiredEvent: DispatchTime?

    private let queue = DispatchQueue(label: "dev.noix.MacCommander.DirectoryWatcher")
    private let source: any DispatchSourceFileSystemObject
    private let debounceInterval: DispatchTimeInterval
    private let maxLatencyInterval: DispatchTimeInterval
    private let onChange: @Sendable () -> Void

    /// Returns nil if `url` can't be opened (e.g. unsupported file systems).
    /// `onChange` is called on a background queue, debounced: it fires `debounce` after the
    /// last event, but at most `maxLatency` after the first unfired event, so a continuous
    /// stream of events still produces periodic callbacks.
    public init?(
        url: URL,
        debounce: Duration = .milliseconds(200),
        maxLatency: Duration = .seconds(1),
        onChange: @escaping @Sendable () -> Void
    ) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        self.debounceInterval = Self.interval(debounce)
        self.maxLatencyInterval = Self.interval(maxLatency)
        self.onChange = onChange
        self.source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: queue)

        source.setEventHandler { [weak self] in self?.scheduleFire() }
        // The only place the fd is closed; runs exactly once after cancel().
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { cancel() }

    /// Stops watching and closes the descriptor. Idempotent. No new callback starts after this
    /// returns, though one already in flight on the background queue may still finish if
    /// `cancel()` races with it from another thread.
    public func cancel() {
        let item: DispatchWorkItem? = lock.withLock {
            guard !isCancelled else { return nil }
            isCancelled = true
            let p = pending
            pending = nil
            return p ?? DispatchWorkItem {}
        }
        guard let item else { return }
        item.cancel()
        source.cancel()
    }

    private func scheduleFire() {
        lock.withLock {
            guard !isCancelled else { return }
            pending?.cancel()
            let now = DispatchTime.now()
            let first = firstUnfiredEvent ?? now
            firstUnfiredEvent = first
            let item = DispatchWorkItem { [weak self] in self?.fire() }
            pending = item
            queue.asyncAfter(deadline: min(now + debounceInterval, first + maxLatencyInterval), execute: item)
        }
    }

    /// Converts a Duration to a DispatchTimeInterval, clamping to avoid overflow.
    private static func interval(_ d: Duration) -> DispatchTimeInterval {
        let c = d.components
        guard c.seconds >= 0 else { return .nanoseconds(0) }
        let (ns, overflow) = c.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow, ns < Int64(Int.max) / 2 else { return .seconds(Int.max / 4_000_000_000) }
        return .nanoseconds(Int(ns + c.attoseconds / 1_000_000_000))
    }

    private func fire() {
        let cancelled = lock.withLock {
            firstUnfiredEvent = nil
            return isCancelled
        }
        if !cancelled { onChange() }
    }
}
