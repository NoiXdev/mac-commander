import AppKit
import MacCommanderCore
import Observation
import SwiftUI

/// Per-window state of the network share sheets (Connect to Server and sign-in), shared by the window, the
/// sidebar and the menu command.
@MainActor @Observable
final class ShareSheets {
    var showConnectToServer = false
    /// The share the sign-in sheet is shown for.
    var signIn: SavedShare? {
        didSet { if signIn == nil { signInPane = nil } }
    }
    /// The pane whose Disconnected placeholder asked for the sign-in; it navigates once signed in. nil (a
    /// request from the sidebar, ⌘K or a queued launch sign-in): the window's active pane.
    @ObservationIgnored weak var signInPane: BrowserModel?
    /// The share the Edit sheet is shown for.
    var editing: SavedShare?
    /// Go to Folder (owned by the window; mirrored here so the share commands can see it).
    var showGoToFolder = false

    /// Whether any of the window's sheets is up; ⌘K is disabled meanwhile.
    var isPresentingSheet: Bool {
        showConnectToServer || signIn != nil || editing != nil || showGoToFolder
    }
    /// The window the sheets and alerts belong to (set by `WindowReader`).
    @ObservationIgnored let window = WindowBox()
}

/// The user-facing connect flow shared by the sidebar, Connect to Server and the sign-in sheet: connects a
/// saved share and turns the outcome into navigation, the sign-in sheet or an alert on the window.
@MainActor
enum ShareActions {
    /// A click on a share that isn't connected (or a Retry): probes and mounts with the saved methods. With no
    /// `model` (the Settings window) it only connects; nothing navigates. `pane`: the pane that asked (its
    /// Disconnected placeholder); a sign-in sheet this leads to navigates that pane (see `showSignIn`).
    static func connect(
        _ share: SavedShare, manager: ShareManager, model: BrowserModel?, sheets: ShareSheets,
        pane: BrowserModel? = nil
    ) async {
        let outcome = await manager.connect(share.id)
        await handle(outcome, for: share, manager: manager, model: model, sheets: sheets, pane: pane)
    }

    /// "Reconnect" in a window's Disconnected placeholder: the same flow as a click on the share. Once
    /// connected, the window returns to the folder it showed (see `handle`).
    static func reconnect(
        _ disconnected: DisconnectedShare, store: ShareStore, manager: ShareManager, model: BrowserModel,
        sheets: ShareSheets
    ) async {
        guard let share = store.shares.first(where: { $0.id == disconnected.id }) else { return }
        await connect(share, manager: manager, model: model, sheets: sheets, pane: model)
    }

    /// Connected: a window showing the share's Disconnected placeholder returns to the same folder under the
    /// (possibly renamed) mount point via `BrowserModel.shareDidConnect`; otherwise (⌘K, sign-in, a sidebar
    /// click) the window goes to the share's folder: the mount point, plus the saved address's folder inside
    /// an smb/afp share (`ShareURL.folder(atMountPoint:)`). Needs sign-in: the sign-in sheet, once no other
    /// sheet is up. Unreachable: the "can’t be reached" alert, whose Retry connects again. Failed: an alert with the message.
    /// With no `model` (the Settings window) a connected share stays where it is: nothing navigates.
    static func handle(
        _ outcome: ConnectOutcome, for share: SavedShare, manager: ShareManager, model: BrowserModel?,
        sheets: ShareSheets, pane: BrowserModel? = nil
    ) async {
        switch outcome {
        case .connected(let mountPoint):
            guard let model else { return }
            guard await !model.shareDidConnect(id: share.id, mountPoint: mountPoint) else { return }
            await model.navigate(to: share.url.folder(atMountPoint: mountPoint))
        case .needsSignIn:
            await showSignIn(share, sheets: sheets, pane: pane)
        case .unreachable:
            await showUnreachable(share, manager: manager, model: model, sheets: sheets, pane: pane)
        case .failed(let message):
            await waitForSheetToClose(sheets.window.window)
            FileActions.showAlert(
                [String(localized: "“\(share.name)” couldn’t be connected: \(message)")], window: sheets.window.window)
        }
    }

    /// The alert for a share whose server doesn't answer: Retry connects again, Cancel does nothing.
    static func showUnreachable(
        _ share: SavedShare, manager: ShareManager, model: BrowserModel?, sheets: ShareSheets,
        pane: BrowserModel? = nil
    ) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(share.name)” can’t be reached from this network.")
        alert.addButton(withTitle: String(localized: "Retry"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard await run(alert, window: sheets.window.window) == .alertFirstButtonReturn else { return }
        await connect(share, manager: manager, model: model, sheets: sheets, pane: pane)
    }

    /// Unmounts the share (forced while its server is unreachable); an error is shown on the window.
    static func disconnect(_ share: SavedShare, manager: ShareManager, sheets: ShareSheets) async {
        do {
            try await manager.disconnect(share.id)
        } catch {
            let message: String
            switch error {
            case .failed(let detail): message = detail
            case .unreachable: message = String(localized: "The server can’t be reached.")
            case .cancelled: message = String(localized: "The operation was cancelled.")
            case .authenticationFailed: message = String(localized: "The server refused the request.")
            case .alreadyMounted: message = String(localized: "The share is in use.")
            }
            FileActions.showAlert(
                [String(localized: "“\(share.name)” couldn’t be disconnected: \(message)")],
                window: sheets.window.window)
        }
    }

    /// Asks to remove the share from the sidebar. It stays mounted and its Keychain item is kept.
    static func confirmRemove(_ share: SavedShare, manager: ShareManager, sheets: ShareSheets) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove “\(share.name)” from the sidebar?")
        alert.informativeText = String(
            localized:
                "The share stays connected until you disconnect it. Saved passwords are kept in the Keychain.")
        let remove = alert.addButton(withTitle: String(localized: "Remove"))
        remove.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        // Cancel is the default button (Return); Remove has no key equivalent.
        remove.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        guard await run(alert, window: sheets.window.window) == .alertFirstButtonReturn else { return }
        await manager.remove(share.id)
    }

    /// Shows the sign-in sheet for `share`. While another sheet of the window is up (or still animating out)
    /// the request waits for it to close, however long that takes, so it is never dropped; it is dropped only
    /// when the window closes. `pane`: the pane that asked; the sheet navigates it once signed in (nil: the
    /// window's active pane).
    static func showSignIn(_ share: SavedShare, sheets: ShareSheets, pane: BrowserModel? = nil) async {
        while sheets.isPresentingSheet || sheets.window.window?.attachedSheet != nil {
            if sheets.signIn?.id == share.id { return }
            guard let window = sheets.window.window, window.isVisible else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        sheets.signInPane = pane
        sheets.signIn = share
    }

    /// As a sheet on the window, or app-modal when there is none or it already shows a sheet.
    private static func run(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        await waitForSheetToClose(window)
        if let window, window.isVisible, window.attachedSheet == nil {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }

    /// A sheet that was just dismissed (Connect to Server, sign-in) stays attached while it animates out; the
    /// next sheet or alert waits for it (at most about a second) so it isn't dropped or shown app-modal.
    private static func waitForSheetToClose(_ window: NSWindow?) async {
        for _ in 0..<20 {
            guard window?.attachedSheet != nil else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
