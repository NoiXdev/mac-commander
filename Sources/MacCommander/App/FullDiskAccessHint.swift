import AppKit
import MacCommanderCore

/// The offer to grant Full Disk Access: once at launch (queued, if it isn't granted) and from Settings.
@MainActor
enum FullDiskAccessHint {
    /// At launch: checks off the main thread and queues the hint only when access is missing and the hint
    /// wasn't shown before.
    static func enqueueIfNeeded(preferences: PreferencesStore) {
        guard !preferences.preferences.didShowFullDiskAccessHint else { return }
        Task {
            let granted = await PathQueries.run { FullDiskAccess.isGranted() }
            guard !granted else { return }
            LaunchAlertQueue.shared.enqueue { present(preferences: preferences) }
        }
    }

    /// Shows the alert now. Whichever button is chosen, the hint counts as shown.
    static func present(preferences: PreferencesStore) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.string("app.fullDiskAccess.title", "Give MacCommander Full Disk Access?")
        alert.informativeText = L10n.string("app.fullDiskAccess.message", "MacCommander works without it, but macOS will ask for permission folder by folder, and some locations (like Mail or Safari data) stay hidden. You can grant access in System Settings › Privacy & Security › Full Disk Access.")
        alert.addButton(withTitle: L10n.string("app.fullDiskAccess.openSettings", "Open System Settings"))
        alert.addButton(withTitle: L10n.string("app.fullDiskAccess.notNow", "Not Now"))
        let response = alert.runModal()
        preferences.preferences.didShowFullDiskAccessHint = true
        if response == .alertFirstButtonReturn {
            PathQueries.openWithDefaultApp(FullDiskAccess.settingsURL)
        }
    }
}
