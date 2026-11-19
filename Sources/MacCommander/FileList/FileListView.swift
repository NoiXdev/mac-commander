import AppKit
import MacCommanderCore
import SwiftUI

/// Copy/move to the other pane, for the list's keys (F5/F6) and context menu; they act on the active pane.
struct PaneCommands {
    /// `PaneLayout.transferRequest(move: false) != nil`.
    let canTransfer: () -> Bool
    /// `PaneLayout.requestTransfer(move:)`: shows the confirmation sheet; false (caller beeps) when impossible.
    let requestTransfer: (_ move: Bool) -> Bool
}

/// SwiftUI wrapper around the AppKit file list.
struct FileListView: NSViewControllerRepresentable {
    let model: BrowserModel
    let settings: ViewSettingsStore
    let clipboard: FileClipboard
    /// "Reconnect" in the Disconnected placeholder of a dropped network share.
    var reconnect: ((DisconnectedShare) -> Void)? = nil
    /// "Sign In…" in the same placeholder.
    var signIn: ((DisconnectedShare) -> Void)? = nil
    /// The list took keyboard focus, or its placeholder was clicked: make its pane the active one.
    var onActivate: (() -> Void)? = nil
    /// Tab / ⇧Tab in the list; nil (single-pane mode) keeps the default key-view loop.
    var onSwitchPane: (() -> Void)? = nil
    /// nil while dual-pane mode isn't enabled or the window is single-pane (F5/F6 beep, no context items).
    var paneCommands: PaneCommands? = nil
    /// An inline rename started (true) or ended (false).
    var onRenamingChanged: ((Bool) -> Void)? = nil
    /// `PaneLayout.focusSerial`: the list takes keyboard focus when it changed and `isFocusTarget` is true.
    var focusSerial = 0
    var isFocusTarget = false
    /// The list's pane is active; only an active pane's list takes keyboard focus when it appears.
    var isActive = true
    @Environment(\.openWindow) private var openWindow

    func makeNSViewController(context: Context) -> FileListController {
        let controller = FileListController(
            model: model, settings: settings, clipboard: clipboard,
            openInfo: { [openWindow] url in openWindow(id: "info", value: url) })
        controller.reconnect = reconnect
        controller.signIn = signIn
        controller.onActivate = onActivate
        controller.onSwitchPane = onSwitchPane
        controller.paneCommands = paneCommands
        controller.onRenamingChanged = onRenamingChanged
        controller.takesFocusOnAppear = isActive
        // A request made before this list existed isn't for it.
        controller.appliedFocusSerial = focusSerial
        return controller
    }

    func updateNSViewController(_ controller: FileListController, context: Context) {
        // The controller observes the model and settings itself.
        controller.openInfo = { [openWindow] url in openWindow(id: "info", value: url) }
        controller.reconnect = reconnect
        controller.signIn = signIn
        controller.onActivate = onActivate
        controller.onSwitchPane = onSwitchPane
        controller.paneCommands = paneCommands
        controller.onRenamingChanged = onRenamingChanged
        controller.takesFocusOnAppear = isActive
        controller.applyFocusRequest(serial: focusSerial, isTarget: isFocusTarget)
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
    /// A click anywhere on the placeholder (its pane becomes active); the buttons still work.
    var onClick: (() -> Void)? = nil

    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    var body: some View {
        placeholder
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { onClick?() })
    }

    @ViewBuilder private var placeholder: some View {
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
