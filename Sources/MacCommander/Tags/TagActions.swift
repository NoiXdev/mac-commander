import AppKit
import MacCommanderCore

/// Creating, renaming, recoloring and deleting tags, with their prompts, confirmations and error alerts. Shared
/// by the sidebar's Tags section and Settings ▸ Tags. Renaming and deleting change every file Spotlight finds
/// with the tag in the home folder; Finder's standard color tags are left alone (`TagEditor`).
@MainActor
enum TagActions {
    static func editor(_ preferences: PreferencesStore) -> TagEditor {
        TagEditor(catalog: .shared, preferences: preferences, finder: SpotlightTagFinder())
    }

    /// Asks for a name and a color and adds the tag (no file has it yet).
    static func create(_ preferences: PreferencesStore) {
        Task {
            let popup = colorPopUp(selected: .none)
            guard let name = await askForName(
                title: String(localized: "New Tag"),
                message: String(localized: "Enter a name and choose a color for the new tag."),
                button: String(localized: "Add"), initial: "", extra: popup)
            else { return }
            let color = TagColor(rawValue: popup.selectedTag()) ?? .none
            await run { try await editor(preferences).create(FileTag(name: name, color: color)) }
        }
    }

    static func rename(_ tag: FileTag, _ preferences: PreferencesStore) {
        Task {
            let editor = editor(preferences)
            let count = await editor.files(with: tag).count
            guard let name = await askForName(
                title: String(localized: "Rename “\(tag.name)”"),
                message: count == 0
                    ? String(localized: "No file has this tag yet.")
                    : String(localized: "The tag is renamed on \(count) files."),
                button: String(localized: "Rename"), initial: tag.name, extra: nil)
            else { return }
            await run { try await editor.rename(tag, to: name) }
        }
    }

    static func recolor(_ tag: FileTag, to color: TagColor, _ preferences: PreferencesStore) {
        Task { await run { try await editor(preferences).recolor(tag, to: color) } }
    }

    static func delete(_ tag: FileTag, _ preferences: PreferencesStore) {
        Task {
            let editor = editor(preferences)
            let count = await editor.files(with: tag).count
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Delete the tag “\(tag.name)”?")
            alert.informativeText = count == 0
                ? String(localized: "No file has this tag.")
                : String(localized: "It is removed from \(count) files.")
            alert.addButton(withTitle: String(localized: "Delete Tag")).hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard await present(alert) == .alertFirstButtonReturn else { return }
            await run { try await editor.delete(tag) }
        }
    }

    /// The localized name of a tag color, as Finder names it ("None" for no color).
    static func colorName(_ color: TagColor) -> String {
        let names = NSWorkspace.shared.fileLabels
        return names.indices.contains(color.rawValue) ? names[color.rawValue] : String(localized: "None")
    }

    /// No color first, then Finder's order.
    static let colorChoices: [TagColor] = [.none] + TagColor.finderOrder

    private static func colorPopUp(selected: TagColor) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        for color in colorChoices {
            popup.addItem(withTitle: colorName(color))
            popup.lastItem?.image = TagMenu.dotImage(color)
            popup.lastItem?.tag = color.rawValue
        }
        popup.selectItem(withTag: selected.rawValue)
        return popup
    }

    /// A name prompt; nil when cancelled, empty or unchanged. `extra` goes under the name field.
    private static func askForName(
        title: String, message: String, button: String, initial: String, extra: NSView?
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Tag name")
        field.stringValue = initial
        if let extra {
            let stack = NSStackView(views: [field, extra])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 240, height: 58)
            alert.accessoryView = stack
        } else {
            alert.accessoryView = field
        }
        alert.window.initialFirstResponder = field
        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        // A pasted newline would split the xattr entry: control characters become spaces.
        let name = TagStore.sanitizedName(field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == initial ? nil : name
    }

    /// As a sheet on the key window when it can take one, else modal.
    private static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow, window.isVisible, window.attachedSheet == nil {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }

    private static func run(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            _ = await present(NSAlert(error: error))
        }
    }
}
