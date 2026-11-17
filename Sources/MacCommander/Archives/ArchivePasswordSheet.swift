import AppKit

/// Asks for an encrypted archive's password: an alert with a secure text field, as a sheet on the
/// window (app-modal when there is none, or the window already shows a sheet). Used by the list's
/// "Enter Password…" button and when an extraction needs a password.
@MainActor
enum ArchivePasswordSheet {
    /// The entered password, or nil when cancelled. `incorrect` adds a note that the last try was wrong.
    static func ask(for archive: URL, incorrect: Bool = false, window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Enter the password for “\(archive.lastPathComponent)”")
        if incorrect {
            alert.informativeText = String(localized: "The password you entered is incorrect.")
        }
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Password")
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
