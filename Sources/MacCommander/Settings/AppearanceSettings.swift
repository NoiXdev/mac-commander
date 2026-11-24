import MacCommanderCore
import SwiftUI

/// View settings: the checkbox column, hidden files and dual-pane mode.
struct AppearanceSettings: View {
    @Environment(ViewSettingsStore.self) private var settings
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Show checkbox column"), isOn: Bindable(settings).settings.showCheckboxColumn)
                Toggle(String(localized: "Show hidden files"), isOn: Bindable(settings).settings.showHiddenFiles)
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        String(localized: "Enable dual-pane mode"),
                        isOn: Bindable(preferences).preferences.dualPaneEnabled)
                    Text(String(localized: "Adds a second folder pane to windows (View ▸ Dual Pane, ⌘2)."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
