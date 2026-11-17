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
    var signIn: SavedShare?
    /// The window the sheets and alerts belong to (set by `WindowReader`).
    @ObservationIgnored let window = WindowBox()
}

/// The user-facing connect flow shared by the sidebar, Connect to Server and the sign-in sheet: connects a
/// saved share and turns the outcome into navigation, the sign-in sheet or an alert on the window.
@MainActor
enum ShareActions {
    /// A click on a share that isn't connected (or a Retry): probes and mounts with the saved methods.
    static func connect(_ share: SavedShare, manager: ShareManager, model: BrowserModel, sheets: ShareSheets) async {
        let outcome = await manager.connect(share.id)
        await handle(outcome, for: share, manager: manager, model: model, sheets: sheets)
    }

    /// Connected: the window goes to the mount point. Needs sign-in: the sign-in sheet. Unreachable: the
    /// "can’t be reached" alert, whose Retry connects again. Failed: an alert with the message.
    static func handle(
        _ outcome: ConnectOutcome, for share: SavedShare, manager: ShareManager, model: BrowserModel,
        sheets: ShareSheets
    ) async {
        switch outcome {
        case .connected(let mountPoint):
            await model.navigate(to: mountPoint)
        case .needsSignIn:
            await waitForSheetToClose(sheets.window.window)
            sheets.signIn = share
        case .unreachable:
            await showUnreachable(share, manager: manager, model: model, sheets: sheets)
        case .failed(let message):
            await waitForSheetToClose(sheets.window.window)
            FileActions.showAlert(
                [String(localized: "“\(share.name)” couldn’t be connected: \(message)")], window: sheets.window.window)
        }
    }

    /// The alert for a share whose server doesn't answer: Retry connects again, Cancel does nothing.
    static func showUnreachable(
        _ share: SavedShare, manager: ShareManager, model: BrowserModel, sheets: ShareSheets
    ) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "“\(share.name)” can’t be reached from this network.")
        alert.addButton(withTitle: String(localized: "Retry"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard await run(alert, window: sheets.window.window) == .alertFirstButtonReturn else { return }
        await connect(share, manager: manager, model: model, sheets: sheets)
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
            }
            FileActions.showAlert(
                [String(localized: "“\(share.name)” couldn’t be disconnected: \(message)")],
                window: sheets.window.window)
        }
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
