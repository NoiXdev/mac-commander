import AppKit
import MacCommanderCore
import SwiftUI

/// General settings: the folder new windows open, the default name for new files, "Show in Finder", the update
/// check and the Full Disk Access hint.
struct GeneralSettings: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(UpdateCheckModel.self) private var updates
    /// The Settings window, so the folder panel can be a sheet on it.
    private let windowState = State(initialValue: WindowBox())
    /// The global `NSFileViewer` value, re-read each time the pane appears (another app may have changed it).
    private let fileViewerState = State(initialValue: false)
    private let fileViewer = FileViewerSetting(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.noix.MacCommander", store: CFGlobalDefaultsStore())

    private static let bundleIdentifier = Bundle.main.bundleIdentifier
    /// Mirrors the stored choice for the picker; the stored value itself is the only source of truth. Starts from
    /// it, so the first frame already shows the choice; `.system` without a bundle identifier, where no picker shows.
    private let languageState = State(
        initialValue: GeneralSettings.bundleIdentifier.map { AppLanguageSetting(domain: $0).current } ?? .system)

    var body: some View {
        Form {
            if let setting = languageSetting {
                Section {
                    Picker(selection: languageBinding(setting)) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.nativeName).tag(language)
                        }
                    } label: {
                        L10n.text("settings.general.language.header", "Language")
                    }
                    if languageState.wrappedValue != AppRelauncher.launchLanguage {
                        Button(action: AppRelauncher.relaunch) {
                            L10n.text("settings.general.language.relaunch", "Relaunch MacCommander")
                        }
                    }
                    L10n.text("settings.general.language.footer", "Takes effect after a relaunch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent(L10n.string("settings.general.newWindows", "New windows open:")) {
                    HStack {
                        Text(folderDescription)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(preferences.preferences.newWindowFolderPath ?? "")
                        Button(L10n.string("settings.general.newWindows.choose", "Choose…"), action: chooseFolder)
                        Button(L10n.string("settings.general.newWindows.home", "Home")) { preferences.preferences.newWindowFolderPath = nil }
                            .disabled(preferences.preferences.newWindowFolderPath == nil)
                    }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        L10n.string("settings.general.newFileName.label", "Default name for new files"),
                        text: Bindable(preferences).preferences.newFileName,
                        prompt: Text(Preferences.builtInNewFileName))
                    if !preferences.preferences.newFileName.isEmpty,
                        !Preferences.isValidFileName(preferences.preferences.newFileName)
                    {
                        Text(L10n.format("settings.general.newFileName.invalid", "Not a valid file name; “%@” is used.", Preferences.builtInNewFileName))
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.string("settings.general.fileViewer", "Use MacCommander for “Show in Finder”"), isOn: fileViewerEnabled)
                    L10n.text("settings.general.fileViewer.footer", "Other apps’ “Show in Finder” opens a MacCommander window. Folders opened from Spotlight or the Dock still open in the Finder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(
                    L10n.string("settings.general.updates.automatic", "Check for updates automatically"),
                    isOn: Bindable(preferences).preferences.updateCheckEnabled)
                LabeledContent(L10n.string("settings.general.updates.label", "Updates:")) {
                    Button(L10n.string("settings.general.updates.checkNow", "Check Now")) {
                        Task { await updates.check(manual: true, preferences: preferences) }
                    }
                    .disabled(updates.isChecking)
                }
            }
            Section {
                LabeledContent(L10n.string("settings.general.fullDiskAccess.label", "Full Disk Access:")) {
                    Button(L10n.string("settings.general.fullDiskAccess.button", "Full Disk Access…")) {
                        FullDiskAccessHint.present(preferences: preferences)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .background(WindowReader(box: windowState.wrappedValue))
        .onAppear {
            fileViewerState.wrappedValue = fileViewer.isEnabled
            if let setting = languageSetting { languageState.wrappedValue = setting.current }
        }
    }

    /// Nil without a bundle identifier (a bare `swift run`), where there is no app domain to hold the choice.
    private var languageSetting: AppLanguageSetting? {
        Self.bundleIdentifier.map { AppLanguageSetting(domain: $0) }
    }

    private func languageBinding(_ setting: AppLanguageSetting) -> Binding<AppLanguage> {
        Binding(
            get: { languageState.wrappedValue },
            set: { language in
                setting.current = language
                languageState.wrappedValue = setting.current
            })
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
        guard let path = preferences.preferences.newWindowFolderPath else { return L10n.string("settings.general.newWindows.home", "Home") }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.string("settings.general.newWindows.panelPrompt", "Choose")
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
