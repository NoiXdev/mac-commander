import AppKit
import MacCommanderCore
import SwiftUI

/// Terminal settings: the app "Open in Terminal" uses. Only installed terminals are offered.
struct TerminalSettings: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Terminal app:"), selection: terminalApp) {
                    ForEach(installedTerminals, id: \.self) { app in
                        Text(app.displayName).tag(app)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Terminal plus iTerm when it's installed (Terminal ships with macOS).
    private var installedTerminals: [TerminalApp] {
        TerminalApp.allCases.filter { $0 == .terminal || Self.isInstalled($0) }
    }

    /// The effective app (see `TerminalApp.effective`); picking one stores it as the choice.
    private var terminalApp: Binding<TerminalApp> {
        Binding(
            get: { TerminalApp.effective(chosen: preferences.preferences.terminalApp, isInstalled: Self.isInstalled) },
            set: { preferences.preferences.terminalApp = $0 })
    }

    private static func isInstalled(_ app: TerminalApp) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) != nil
    }
}
