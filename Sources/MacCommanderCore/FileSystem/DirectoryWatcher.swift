import Foundation

public final class DirectoryWatcher: @unchecked Sendable {
    // @unchecked Sendable is safe because all mutable state (`isCancelled`,
    // `pending`) is only touched while holding `lock`; `source` and `queue`
    // are immutable after init and themselves thread-safe.
    private let lock = NSLock()
    private var isCancelled = false
    private var pending: DispatchWorkItem?

    private let queue = DispatchQueue(label: "dev.noix.MacCommander.DirectoryWatcher")
    private let source: any DispatchSourceFileSystemObject
    private let debounceInterval: DispatchTimeInterval
    private let onChange: @Sendable () -> Void

    /// Returns nil if `url` can't be opened (e.g. unsupported file systems).
    /// `onChange` is called on a background queue, debounced.
    public init?(
        url: URL,
        debounce: Duration = .milliseconds(200),
        onChange: @escaping @Sendable () -> Void
    ) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let c = debounce.components
        let nanos = max(0, c.seconds) * 1_000_000_000 + c.attoseconds / 1_000_000_000
        self.debounceInterval = .nanoseconds(Int(clamping: nanos))
        self.onChange = onChange
        self.source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link], queue: queue)

        source.setEventHandler { [weak self] in self?.scheduleFire() }
        // The only place the fd is closed; runs exactly once after cancel().
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { cancel() }

    /// Stops watching and closes the descriptor. Idempotent; no callback fires afterwards.
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
            let item = DispatchWorkItem { [weak self] in self?.fire() }
            pending = item
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
        }
    }

    private func fire() {
        let cancelled = lock.withLock { isCancelled }
        if !cancelled { onChange() }
    }
}
