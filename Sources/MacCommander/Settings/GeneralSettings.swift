import AppKit
import MacCommanderCore
import SwiftUI

/// General settings: list columns and hidden files, the default name for new files, the folder new windows
/// open, and the Full Disk Access hint.
struct GeneralSettings: View {
    @Environment(ViewSettingsStore.self) private var settings
    @Environment(PreferencesStore.self) private var preferences
    /// The Settings window, so the folder panel can be a sheet on it.
    private let windowState = State(initialValue: WindowBox())

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
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        String(localized: "Default name for new files"),
                        text: Bindable(preferences).preferences.newFileName)
                    if !Preferences.isValidFileName(preferences.preferences.newFileName) {
                        Text(String(localized: "Not a valid file name; “untitled.txt” is used."))
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section {
                LabeledContent(String(localized: "New windows open:")) {
                    HStack {
                        Text(folderDescription)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(preferences.preferences.newWindowFolderPath ?? "")
                        Button(String(localized: "Choose…"), action: chooseFolder)
                        Button(String(localized: "Home")) { preferences.preferences.newWindowFolderPath = nil }
                            .disabled(preferences.preferences.newWindowFolderPath == nil)
                    }
                }
            }
            Section {
                LabeledContent(String(localized: "Full Disk Access:")) {
                    Button(String(localized: "Full Disk Access…")) {
                        FullDiskAccessHint.present(preferences: preferences)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .background(WindowReader(box: windowState.wrappedValue))
    }

    /// The chosen folder's path with `~` for home, or "Home".
    private var folderDescription: String {
        guard let path = preferences.preferences.newWindowFolderPath else { return String(localized: "Home") }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        if let path = preferences.preferences.newWindowFolderPath {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        let preferences = preferences
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            preferences.preferences.newWindowFolderPath = url.path
        }
        if let window = windowState.wrappedValue.window, window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { apply(response) }
            }
        } else {
            apply(panel.runModal())
        }
    }
}
