import AppKit
import MacCommanderCore

/// Asks the user how to resolve a name conflict during a copy or move, as an alert sheet on the window.
///
/// One prompter serves the whole app: conflicts that arrive at the same time (several operations
/// running) are asked one after another, never as stacked dialogs.
@MainActor
final class ConflictPrompter {
    static let shared = ConflictPrompter()

    /// The newest question; each question waits for the one before it.
    private var tail: Task<Void, Never>?

    /// A resolver that shows its questions on `window` (app-modal when there is none).
    func resolver(for window: NSWindow?) -> ConflictResolver {
        { [weak window] conflict in
            await self.ask(conflict, on: window)
        }
    }

    private func ask(_ conflict: TransferConflict, on window: NSWindow?) async -> ConflictDecision {
        let previous = tail
        let question = Task { @MainActor () -> ConflictDecision in
            await previous?.value
            return await Self.present(conflict, on: window)
        }
        tail = Task { _ = await question.value }
        return await question.value
    }

    /// Buttons, in order: Keep Both (default, Return), Replace, Skip, Stop (Esc).
    private static func present(_ conflict: TransferConflict, on window: NSWindow?) async -> ConflictDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let name = conflict.existing.lastPathComponent
        alert.messageText = String(localized: "An item named “\(name)” already exists in this location.")
        alert.informativeText =
            conflict.mode == .copy
            ? String(localized: "Do you want to replace it with the one you’re copying?")
            : String(localized: "Do you want to replace it with the one you’re moving?")
        alert.addButton(withTitle: String(localized: "Keep Both"))
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Skip"))
        let stop = alert.addButton(withTitle: String(localized: "Stop"))
        stop.keyEquivalent = "\u{1b}"
        if conflict.moreItemsFollow {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Apply to All")
        }

        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        let choice: ConflictChoice
        switch response {
        case .alertFirstButtonReturn: choice = .keepBoth
        case .alertSecondButtonReturn: choice = .replace
        case .alertThirdButtonReturn: choice = .skip
        default: choice = .stop
        }
        let applyToAll = conflict.moreItemsFollow && alert.suppressionButton?.state == .on
        return ConflictDecision(choice: choice, applyToAll: applyToAll)
    }
}
