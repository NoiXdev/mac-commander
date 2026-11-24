import AppKit
import MacCommanderCore
import SwiftUI

/// General settings: the folder new windows open, the default name for new files, "Show in Finder", and the
/// Full Disk Access hint.
struct GeneralSettings: View {
    @Environment(PreferencesStore.self) private var preferences
    /// The Settings window, so the folder panel can be a sheet on it.
    private let windowState = State(initialValue: WindowBox())
    /// The global `NSFileViewer` value, re-read each time the pane appears (another app may have changed it).
    private let fileViewerState = State(initialValue: false)
    private let fileViewer = FileViewerSetting(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.noix.MacCommander", store: CFGlobalDefaultsStore())

    var body: some View {
        Form {
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
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(String(localized: "Use MacCommander for “Show in Finder”"), isOn: fileViewerEnabled)
                    Text(String(localized: "Other apps’ “Show in Finder” opens a MacCommander window. Folders opened from Spotlight or the Dock still open in the Finder."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
        .onAppear { fileViewerState.wrappedValue = fileViewer.isEnabled }
    }

    /// Writes the global value, then shows what is actually stored.
    private var fileViewerEnabled: Binding<Bool> {
        Binding(
            get: { fileViewerState.wrappedValue },
            set: { [fileViewer] on in
                fileViewer.setEnabled(on)
                fileViewerState.wrappedValue = fileViewer.isEnabled
            })
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
