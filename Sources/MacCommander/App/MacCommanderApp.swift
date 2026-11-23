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
    /// Owned by the app delegate, which cancels the running operations at quit.
    private var operations: FileOperationCenter { appDelegate.operations }
    private let clipboard = FileClipboard()

    var body: some Scene {
        // Opened by id through `OpenRequestRouter`. External open events (reveals, folders) go to the app
        // delegate only: the router makes their windows, so SwiftUI mustn't add one of its own.
        WindowGroup(id: BrowserWindow.sceneID) {
            BrowserWindow()
                .environment(settings)
                .environment(preferences)
                .environment(favorites)
                .environment(operations)
                .environment(clipboard)
                .environment(appDelegate.shares.store)
                .environment(appDelegate.shares.manager)
                .environment(appDelegate.router)
        }
        .handlesExternalEvents(matching: [])
        .commands {
            BrowserCommands(settings: settings, preferences: preferences)
        }

        // One window per item; opening the same URL again focuses the existing window.
        WindowGroup(id: "info", for: URL.self) { $url in
            if let url {
                InfoWindow(url: url, operations: operations)
            }
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(preferences)
                .environment(appDelegate.shares.store)
                .environment(appDelegate.shares.manager)
                .environment(appDelegate.router)
                .environment(appDelegate.hotKeys)
        }
    }
}

/// Purges the archive preview cache (extracted copies for Quick Look and Open) at launch, which also removes
/// leftovers of a session that didn't quit normally, and at quit. Owns the network shares (one store, manager
/// and monitor for the whole app), starts them at launch and stops them at quit. Owns the file operation center,
/// whose running operations it cancels at quit.
/// Starts the tag catalog (`TagCatalog.shared`) and the ffmpeg check (`FFmpegLocator.shared`) at launch.
/// Hands opened folders and items to the `OpenRequestRouter`. Owns the global hotkey and registers the stored
/// one at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// How long quitting waits for cancelled operations, the purge and the share list's last write.
    static let quitTimeout: Duration = .seconds(2)

    let shares = NetworkShares()
    let preferences = PreferencesStore()
    let operations = FileOperationCenter()
    let router = OpenRequestRouter()
    let hotKeys = HotKeyCenter()
    /// Set once quitting was answered (the work finished or the timeout passed).
    private var didReplyToTerminate = false

    /// Our own Reveal in Finder (`activateFileViewerSelecting`) keeps going to the Finder while the global
    /// `NSFileViewer` names this app: the app's own domain overrides the global one for this process only.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set("com.apple.finder", forKey: FileViewerSetting.key)
    }

    /// Reveals from other apps, Dock drops, `open -a` and Open With; on a cold launch before any window exists.
    func application(_ application: NSApplication, open urls: [URL]) {
        router.receive(urls.filter(\.isFileURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        router.launchFinished()
        // A shortcut that's taken stays stored but inactive; Settings shows the problem when it's recorded again.
        let router = router
        _ = hotKeys.register(preferences.preferences.globalShortcut) { router.bringAppToFront() }
        Task { await ArchivePreviewCache.shared.purge() }
        shares.start()
        FullDiskAccessHint.enqueueIfNeeded(preferences: preferences)
        // Custom tag colors and tags created in-app survive restarts (Spotlight knows tag names only).
        let preferences = preferences
        TagCatalog.shared.onKnownChange = { preferences.preferences.knownTags = $0 }
        TagCatalog.shared.start(standard: TagMenu.standardTags(), known: preferences.preferences.knownTags)
        // The Convert menu is built from the cached result and never waits for the check.
        Task { _ = await FFmpegLocator.shared.status() }
    }

    /// With operations running, quitting asks first and then cancels them all. Quitting waits
    /// (`.terminateLater`) for the cancelled operations to end (their tools terminated, temporary folders
    /// removed), the preview cache purge and pending writes of the share list (`ShareStore.flush`), all off
    /// the main thread, but at most `quitTimeout`: the cache's actor may be busy with work on a slow volume.
    /// Then it goes on to `applicationWillTerminate` as usual.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !operations.operations.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Cancel running operations and quit?")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Don't Quit"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        shares.stop()
        didReplyToTerminate = false
        let store = shares.store
        let operations = operations
        Task {
            // Concurrently, so a slow purge doesn't use up the bound before the share list is written.
            async let cancelled: Void = operations.cancelAll()
            async let purged: Void = ArchivePreviewCache.shared.purge()
            async let flushed: Void = store.flush()
            _ = await (cancelled, purged, flushed)
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
