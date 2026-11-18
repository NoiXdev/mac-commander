import AppKit
import MacCommanderCore
import SwiftUI

/// SwiftUI wrapper around the AppKit file list.
struct FileListView: NSViewControllerRepresentable {
    let model: BrowserModel
    let settings: ViewSettingsStore
    let clipboard: FileClipboard
    /// "Reconnect" in the Disconnected placeholder of a dropped network share.
    var reconnect: ((DisconnectedShare) -> Void)? = nil
    /// "Sign In…" in the same placeholder.
    var signIn: ((DisconnectedShare) -> Void)? = nil
    @Environment(\.openWindow) private var openWindow

    func makeNSViewController(context: Context) -> FileListController {
        let controller = FileListController(
            model: model, settings: settings, clipboard: clipboard,
            openInfo: { [openWindow] url in openWindow(id: "info", value: url) })
        controller.reconnect = reconnect
        controller.signIn = signIn
        return controller
    }

    func updateNSViewController(_ controller: FileListController, context: Context) {
        // The controller observes the model and settings itself.
        controller.openInfo = { [openWindow] url in openWindow(id: "info", value: url) }
        controller.reconnect = reconnect
        controller.signIn = signIn
    }
}

/// Shown instead of the list when the folder can't be read. An encrypted archive gets an
/// "Enter Password…" button, which runs `enterPassword`; a dropped network share shows "Disconnected"
/// with a "Reconnect" button, which runs `reconnect`, and a "Sign In…" button, which runs `signIn`.
struct LoadErrorView: View {
    let error: DirectoryLoadError
    var enterPassword: (() -> Void)? = nil
    var reconnect: (() -> Void)? = nil
    var signIn: (() -> Void)? = nil

    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    var body: some View {
        if case .shareDisconnected = error {
            ContentUnavailableView {
                Label(String(localized: "Disconnected"), systemImage: "network.slash")
            } description: {
                Text(error.message)
            } actions: {
                HStack {
                    if let reconnect {
                        Button(String(localized: "Reconnect"), action: reconnect)
                    }
                    if let signIn {
                        Button(String(localized: "Sign In…"), action: signIn)
                    }
                }
            }
        } else {
            unreadableView
        }
    }

    private var unreadableView: some View {
        ContentUnavailableView {
            Label(error.message, systemImage: isPermissionError || needsPassword ? "lock" : "exclamationmark.triangle")
        } actions: {
            if isPermissionError, let url = Self.privacySettingsURL {
                Button(String(localized: "Open Privacy Settings")) {
                    PathQueries.openWithDefaultApp(url)
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
