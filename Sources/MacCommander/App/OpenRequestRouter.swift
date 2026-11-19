import AppKit
import MacCommanderCore
import Observation

/// Turns folders and items handed to the app (other apps' "Show in Finder", Dock drops, `open -a`, Open With)
/// into new browser windows, one per `OpenRequest`. A fresh `BrowserWindow` takes one pending request when it
/// appears (`takePending`); restored windows never do. One for the whole app, owned by `AppDelegate`.
///
/// Cold launch: requests are only queued until the first window registers `openWindow`. That window, when it is
/// fresh, waits for groupings still running (`waitForReceives`), takes one request, and then registers, which
/// opens a window for each request still pending. So a reveal ends with one window at the target, not an extra
/// one at home.
@MainActor @Observable
final class OpenRequestRouter {
    /// How long after launch the router waits for SwiftUI's launch window before opening one itself.
    static let launchWindowGrace: Duration = .milliseconds(500)

    @ObservationIgnored private(set) var pending: [OpenRequest] = []
    /// Opens a new window of the main `WindowGroup` (SwiftUI's `openWindow`, registered by `BrowserWindow`).
    @ObservationIgnored private(set) var openWindow: (() -> Void)?
    private(set) var browserWindowCount = 0
    /// Each browser window's `WindowBox`, held weakly: a box goes away with its closed window's state.
    @ObservationIgnored private var windowBoxes: [WeakWindowBox] = []
    /// `receive` calls whose grouping is still running off the main actor, and the windows waiting for them.
    @ObservationIgnored private var receiving = 0
    @ObservationIgnored private var receiveWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set once the launch window had its chance to appear; until then no fallback window is opened.
    @ObservationIgnored private var isPastLaunch = false
    @ObservationIgnored private var didOpenFallbackWindow = false

    var isReceiving: Bool { receiving > 0 }

    /// Groups `urls` off the main actor (the folder check may block on a network volume), then enqueues them.
    func receive(_ urls: [URL]) {
        receiving += 1
        Task {
            let requests = await PathQueries.run { OpenRequest.requests(for: urls, isFolder: OpenRequest.folderCheck) }
            receiving -= 1
            enqueue(requests)
            if receiving == 0 {
                let waiters = receiveWaiters
                receiveWaiters = []
                waiters.forEach { $0.resume() }
            }
        }
    }

    /// Queues the requests and, once a window has registered `openWindow`, opens one window per request.
    func enqueue(_ requests: [OpenRequest]) {
        guard !requests.isEmpty else { return }
        pending += requests
        if openWindow != nil {
            requests.forEach { _ in openNewWindow() }
        } else {
            openFallbackWindowIfNeeded()
        }
    }

    func takePending() -> OpenRequest? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Returns once no grouping is running.
    func waitForReceives() async {
        guard receiving > 0 else { return }
        await withCheckedContinuation { receiveWaiters.append($0) }
    }

    /// Keeps the newest window's `openWindow`. The first registration opens a window per pending request.
    func register(openWindow: @escaping () -> Void) {
        let isFirst = self.openWindow == nil
        self.openWindow = openWindow
        if isFirst {
            pending.forEach { _ in openNewWindow() }
        }
    }

    func windowAppeared(_ box: WindowBox) {
        browserWindowCount += 1
        windowBoxes.removeAll { $0.box == nil || $0.box === box }
        windowBoxes.append(WeakWindowBox(box: box))
    }

    /// The open browser windows (also minimized ones), in the order they appeared.
    var browserWindows: [NSWindow] {
        windowBoxes.compactMap { $0.box?.window }
    }

    func windowDisappeared() {
        browserWindowCount = max(browserWindowCount - 1, 0)
    }

    /// A new browser window (it starts at the "new window" folder unless a request is pending). With no browser
    /// window open it uses the menu item: the stored `openWindow` belongs to a closed window then.
    func openNewWindow() {
        if browserWindowCount == 0, Self.performNewWindowMenuItem() { return }
        if let openWindow {
            openWindow()
        } else {
            Self.performNewWindowMenuItem()
        }
    }

    /// Called at the end of launching. If SwiftUI shows no window (it may not when launched to open items),
    /// opens one after `launchWindowGrace`, so pending requests aren't stuck.
    func launchFinished() {
        Task {
            try? await Task.sleep(for: Self.launchWindowGrace)
            isPastLaunch = true
            openFallbackWindowIfNeeded()
        }
    }

    /// Opens one window through the menu while none has appeared or registered; it takes a request and then
    /// registers, which opens the rest.
    private func openFallbackWindowIfNeeded() {
        guard isPastLaunch, !didOpenFallbackWindow, openWindow == nil, browserWindowCount == 0,
            !pending.isEmpty || receiving > 0
        else { return }
        didOpenFallbackWindow = true
        Self.performNewWindowMenuItem()
    }

    /// File ▸ New Window (⌘N), the main `WindowGroup`'s own item: the only way to open its window without a view's
    /// `openWindow`. Returns false when the item wasn't found.
    @discardableResult
    static func performNewWindowMenuItem() -> Bool {
        guard let mainMenu = NSApp.mainMenu, let (menu, index) = newWindowItem(in: mainMenu) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    private static func newWindowItem(in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            if item.keyEquivalent == "n", modifiers == .command {
                return (menu, index)
            }
            if let submenu = item.submenu, let found = newWindowItem(in: submenu) { return found }
        }
        return nil
    }
}

private struct WeakWindowBox {
    weak var box: WindowBox?
}
