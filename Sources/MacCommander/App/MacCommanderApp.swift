import MacCommanderCore
import SwiftUI

@main
struct MacCommanderApp: App {
    // The App value is created once, so plain properties are enough (no `@State`).
    private let settings = ViewSettingsStore()
    private let favorites = FavoritesStore()

    var body: some Scene {
        WindowGroup {
            BrowserWindow()
                .environment(settings)
                .environment(favorites)
        }
        .commands {
            BrowserCommands(settings: settings)
        }
    }
}
