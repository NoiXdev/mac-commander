import AppKit
import MacCommanderCore
import SwiftUI

/// General settings: list columns and hidden files, the default name for new files, the folder new windows
/// open, "Show in Finder", the global hotkey, and the Full Disk Access hint.
struct GeneralSettings: View {
    @Environment(ViewSettingsStore.self) private var settings
    @Environment(PreferencesStore.self) private var preferences
    @Environment(OpenRequestRouter.self) private var router
    @Environment(HotKeyCenter.self) private var hotKeys
    /// Set when the last recorded shortcut couldn't be registered.
    private let hotKeyFailedState = State(initialValue: false)
    /// The Settings window, so the folder panel can be a sheet on it.
    private let windowState = State(initialValue: WindowBox())
    /// The global `NSFileViewer` value, re-read each time the pane appears (another app may have changed it).
    private let fileViewerState = State(initialValue: false)
    private let fileViewer = FileViewerSetting(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.noix.MacCommander", store: CFGlobalDefaultsStore())

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
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(String(localized: "Use MacCommander for “Show in Finder”"), isOn: fileViewerEnabled)
                    Text(String(localized: "Other apps’ “Show in Finder” opens a MacCommander window. Folders opened from Spotlight or the Dock still open in the Finder."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(String(localized: "Global hotkey")) {
                        HStack {
                            ShortcutRecorder(shortcut: preferences.preferences.globalShortcut, onRecord: recordHotKey)
                            Button(String(localized: "Clear"), action: clearHotKey)
                                .disabled(preferences.preferences.globalShortcut == nil)
                        }
                    }
                    if hotKeyFailedState.wrappedValue {
                        Text(String(localized: "This shortcut is already in use"))
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section {
                Picker(String(localized: "Terminal app:"), selection: terminalApp) {
                    ForEach(installedTerminals, id: \.self) { app in
                        Text(app.displayName).tag(app)
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

    /// Registers the shortcut first and stores it only when that worked.
    private func recordHotKey(_ shortcut: GlobalShortcut) {
        let router = router
        if hotKeys.register(shortcut, action: { router.bringAppToFront() }) {
            preferences.preferences.globalShortcut = shortcut
            hotKeyFailedState.wrappedValue = false
        } else {
            hotKeyFailedState.wrappedValue = true
        }
    }

    private func clearHotKey() {
        _ = hotKeys.register(nil) {}
        preferences.preferences.globalShortcut = nil
        hotKeyFailedState.wrappedValue = false
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
