import AppKit
import MacCommanderCore
import SwiftUI

@main
struct MacCommanderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The App value is created once, so plain properties are enough (no `@State`).
    private let settings = ViewSettingsStore()
    /// Owned by the app delegate, which needs it at launch (the Full Disk Access hint).
    private var preferences: PreferencesStore { appDelegate.preferences }
    private let favorites = FavoritesStore()
    private let operations = FileOperationCenter()
    private let clipboard = FileClipboard()

    var body: some Scene {
        WindowGroup {
            BrowserWindow()
                .environment(settings)
                .environment(preferences)
                .environment(favorites)
                .environment(operations)
                .environment(clipboard)
                .environment(appDelegate.shares.store)
                .environment(appDelegate.shares.manager)
        }
        .commands {
            BrowserCommands(settings: settings, preferences: preferences)
        }

        // One window per item; opening the same URL again focuses the existing window.
        WindowGroup(id: "info", for: URL.self) { $url in
            if let url {
                InfoWindow(url: url, operations: operations)
            }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(preferences)
                .environment(appDelegate.shares.store)
                .environment(appDelegate.shares.manager)
        }
    }
}

/// Purges the archive preview cache (extracted copies for Quick Look and Open) at launch, which also removes
/// leftovers of a session that didn't quit normally, and at quit. Owns the network shares (one store, manager
/// and monitor for the whole app), starts them at launch and stops them at quit.
/// Starts the tag catalog (`TagCatalog.shared`) at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// How long quitting waits for the purge and the share list's last write.
    static let quitTimeout: Duration = .seconds(2)

    let shares = NetworkShares()
    let preferences = PreferencesStore()
    /// Set once quitting was answered (the work finished or the timeout passed).
    private var didReplyToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await ArchivePreviewCache.shared.purge() }
        shares.start()
        FullDiskAccessHint.enqueueIfNeeded(preferences: preferences)
        TagCatalog.shared.start(standard: TagMenu.standardTags())
    }

    /// Quitting waits (`.terminateLater`) for the preview cache purge and for pending writes of the share list
    /// (`ShareStore.flush`), both off the main thread, but at most `quitTimeout`: the cache's actor may be
    /// busy with work on a slow volume. Then it goes on to `applicationWillTerminate` as usual.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shares.stop()
        didReplyToTerminate = false
        let store = shares.store
        Task {
            // Concurrently, so a slow purge doesn't use up the bound before the share list is written.
            async let purged: Void = ArchivePreviewCache.shared.purge()
            async let flushed: Void = store.flush()
            _ = await (purged, flushed)
            replyToTerminate(sender)
        }
        Task {
            try? await Task.sleep(for: Self.quitTimeout)
            replyToTerminate(sender)
        }
        return .terminateLater
    }

    private func replyToTerminate(_ sender: NSApplication) {
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}

/// The app's network shares: the saved list, the manager that keeps their status, the monitor that feeds it
/// network and volume events, and the "Remember this share?" prompts. One for the whole app, so a prompt is
/// shown once however many windows are open.
@MainActor
final class NetworkShares {
    let store = ShareStore()
    let manager: ShareManager
    private let monitor: NetworkMonitor
    private let prompter: RememberSharePrompter

    init() {
        manager = ShareManager(
            store: store, mounter: NetFSMounter(), prober: TCPReachabilityProber(), volumes: SystemVolumeLister(),
            credentials: KeychainCredentialStore())
        monitor = NetworkMonitor(manager: manager)
        prompter = RememberSharePrompter(manager: manager)
    }

    /// Shows a problem with the share list once, then runs the first check and starts listening for changes.
    func start() {
        if let error = store.persistenceError {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "MacCommander can’t save your network shares: \(error)")
            LaunchAlertQueue.shared.enqueue { alert.runModal() }
        }
        prompter.start()
        monitor.start()
        manager.start()
    }

    func stop() {
        monitor.stop()
        manager.stop()
        prompter.stop()
    }
}

/// Offers each of `ShareManager.rememberPrompts` in turn as an app-modal alert: Remember saves the share, Not Now
/// declines it for good.
@MainActor
final class RememberSharePrompter {
    private let manager: ShareManager
    private var isPresenting = false
    private var isRunning = false

    init(manager: ShareManager) {
        self.manager = manager
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observe()
        presentNext()
    }

    func stop() {
        isRunning = false
    }

    /// Observation fires once per registration, so it registers again on every change.
    private func observe() {
        guard isRunning else { return }
        withObservationTracking {
            _ = manager.rememberPrompts
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                self?.presentNext()
            }
        }
    }

    private func presentNext() {
        guard isRunning, !isPresenting, let mounted = manager.rememberPrompts.first else { return }
        isPresenting = true
        LaunchAlertQueue.shared.enqueue { [self] in
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = String(localized: "Remember this share?")
            alert.informativeText = String(
                localized: "MacCommander can keep “\(mounted.url.displayName)” in the sidebar and reconnect it automatically.")
            alert.addButton(withTitle: String(localized: "Remember"))
            alert.addButton(withTitle: String(localized: "Not Now"))
            let response = alert.runModal()
            isPresenting = false
            if response == .alertFirstButtonReturn {
                manager.remember(mounted)
            } else {
                manager.decline(mounted)
            }
            presentNext()
        }
    }
}
