import AppKit
import MacCommanderCore

/// Asks for an encrypted archive's password: an alert with a secure text field, as a sheet on the
/// window (app-modal when there is none, or the window already shows a sheet). Used by the list's
/// "Enter Password…" button and when an extraction needs a password.
@MainActor
enum ArchivePasswordSheet {
    /// The entered password, or nil when cancelled. `incorrect` adds a note that the last try was wrong.
    static func ask(for archive: URL, incorrect: Bool = false, window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.format("archive.password.title", "Enter the password for “%@”", archive.lastPathComponent)
        if incorrect {
            alert.informativeText = L10n.string("archive.password.incorrect", "The password you entered is incorrect.")
        }
        alert.addButton(withTitle: L10n.string("archive.password.ok", "OK"))
        alert.addButton(withTitle: L10n.string("archive.password.cancel", "Cancel"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L10n.string("archive.password.placeholder", "Password")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response: NSApplication.ModalResponse
        if let window, window.isVisible, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
