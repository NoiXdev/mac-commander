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
        alert.messageText = L10n.format("operation.conflict.title", "An item named “%@” already exists in this location.", name)
        alert.informativeText =
            conflict.mode == .copy
            ? L10n.string("operation.conflict.copying", "Do you want to replace it with the one you’re copying?")
            : L10n.string("operation.conflict.moving", "Do you want to replace it with the one you’re moving?")
        alert.addButton(withTitle: L10n.string("operation.conflict.keepBoth", "Keep Both"))
        alert.addButton(withTitle: L10n.string("operation.conflict.replace", "Replace"))
        alert.addButton(withTitle: L10n.string("operation.conflict.skip", "Skip"))
        let stop = alert.addButton(withTitle: L10n.string("operation.conflict.stop", "Stop"))
        stop.keyEquivalent = "\u{1b}"
        if conflict.moreItemsFollow {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L10n.string("operation.conflict.applyToAll", "Apply to All")
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
