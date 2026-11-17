import MacCommanderCore
import SwiftUI

@main
struct MacCommanderApp: App {
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
