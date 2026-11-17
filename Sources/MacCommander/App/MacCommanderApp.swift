import AppKit
import MacCommanderCore
import SwiftUI

@main
struct MacCommanderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The App value is created once, so plain properties are enough (no `@State`).
    private let settings = ViewSettingsStore()
    private let favorites = FavoritesStore()
    private let operations = FileOperationCenter()
    private let clipboard = FileClipboard()

    var body: some Scene {
        WindowGroup {
            BrowserWindow()
                .environment(settings)
                .environment(favorites)
                .environment(operations)
                .environment(clipboard)
        }
        .commands {
            BrowserCommands(settings: settings)
        }

        // One window per item; opening the same URL again focuses the existing window.
        WindowGroup(id: "info", for: URL.self) { $url in
            if let url {
                InfoWindow(url: url)
            }
        }
        .windowResizability(.contentSize)
    }
}

/// Purges the archive preview cache (extracted copies for Quick Look and Open) at launch, which also removes
/// leftovers of a session that didn't quit normally, and at quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await ArchivePreviewCache.shared.purge() }
    }

    /// Quitting waits for the purge, which runs off the main thread (`.terminateLater`), then goes on to
    /// `applicationWillTerminate` as usual.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await ArchivePreviewCache.shared.purge()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
