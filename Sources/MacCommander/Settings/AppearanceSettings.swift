import MacCommanderCore
import SwiftUI

/// View settings: the checkbox column, hidden files and dual-pane mode.
struct AppearanceSettings: View {
    @Environment(ViewSettingsStore.self) private var settings
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Form {
            Section {
                Toggle(L10n.string("settings.view.showCheckboxColumn", "Show checkbox column"), isOn: Bindable(settings).settings.showCheckboxColumn)
                Toggle(L10n.string("settings.view.showHiddenFiles", "Show hidden files"), isOn: Bindable(settings).settings.showHiddenFiles)
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        L10n.string("settings.view.dualPane", "Enable dual-pane mode"),
                        isOn: Bindable(preferences).preferences.dualPaneEnabled)
                    L10n.text("settings.view.dualPaneFooter", "Adds a second folder pane to windows (View ▸ Dual Pane, ⌘2).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
