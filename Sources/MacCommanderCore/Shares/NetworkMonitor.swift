import AppKit
import Network

/// Feeds system events to a `ShareManager`: network path changes (debounced 2 s, since a Wi-Fi switch reports
/// several in a row) and wake call `networkChanged()`; volume mounts and unmounts call `volumesChanged()`.
/// The first path update after `start()` describes the current network and is ignored: callers do the initial
/// refresh themselves.
@MainActor
public final class NetworkMonitor {
    private weak var manager: ShareManager?
    private var pathMonitor: NWPathMonitor?
    private var debounce: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var sawInitialPath = false

    static let debounceDelay: Duration = .seconds(2)

    public init(manager: ShareManager) {
        self.manager = manager
    }

    public func start() {
        guard pathMonitor == nil else { return }
        sawInitialPath = false
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.pathChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "dev.noix.MacCommander.NetworkMonitor"))
        pathMonitor = monitor

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in await self?.manager?.volumesChanged() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) {
            [weak self] _ in
            Task { @MainActor in await self?.manager?.networkChanged() }
        })
    }

    public func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        debounce?.cancel()
        debounce = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers = []
    }

    private func pathChanged() {
        guard pathMonitor != nil else { return }
        guard sawInitialPath else {
            sawInitialPath = true
            return
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.manager?.networkChanged()
        }
    }
}
