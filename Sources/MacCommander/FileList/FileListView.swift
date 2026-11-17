import AppKit
import MacCommanderCore
import SwiftUI

/// SwiftUI wrapper around the AppKit file list.
struct FileListView: NSViewControllerRepresentable {
    let model: BrowserModel
    let settings: ViewSettingsStore
    let clipboard: FileClipboard
    @Environment(\.openWindow) private var openWindow

    func makeNSViewController(context: Context) -> FileListController {
        FileListController(
            model: model, settings: settings, clipboard: clipboard,
            openInfo: { [openWindow] url in openWindow(id: "info", value: url) })
    }

    func updateNSViewController(_ controller: FileListController, context: Context) {
        // The controller observes the model and settings itself.
        controller.openInfo = { [openWindow] url in openWindow(id: "info", value: url) }
    }
}

/// Shown instead of the list when the folder can't be read. An encrypted archive gets an
/// "Enter Password…" button, which runs `enterPassword`.
struct LoadErrorView: View {
    let error: DirectoryLoadError
    var enterPassword: (() -> Void)? = nil

    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    var body: some View {
        ContentUnavailableView {
            Label(error.message, systemImage: isPermissionError || needsPassword ? "lock" : "exclamationmark.triangle")
        } actions: {
            if isPermissionError, let url = Self.privacySettingsURL {
                Button(String(localized: "Open Privacy Settings")) {
                    NSWorkspace.shared.open(url)
                }
            }
            if needsPassword, let enterPassword {
                Button(String(localized: "Enter Password…"), action: enterPassword)
            }
        }
    }

    private var needsPassword: Bool {
        switch error {
        case .archivePasswordRequired, .archiveIncorrectPassword: true
        default: false
        }
    }

    private var isPermissionError: Bool {
        if case .permissionDenied = error { return true }
        return false
    }
}
