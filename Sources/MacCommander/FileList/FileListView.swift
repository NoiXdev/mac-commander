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

/// Shown instead of the list when the folder can't be read.
struct LoadErrorView: View {
    let error: DirectoryLoadError

    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    var body: some View {
        ContentUnavailableView {
            Label(error.message, systemImage: isPermissionError ? "lock" : "exclamationmark.triangle")
        } actions: {
            if isPermissionError, let url = Self.privacySettingsURL {
                Button(String(localized: "Open Privacy Settings")) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var isPermissionError: Bool {
        if case .permissionDenied = error { return true }
        return false
    }
}
