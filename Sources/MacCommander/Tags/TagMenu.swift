import AppKit
import MacCommanderCore

/// The "Tags" submenu: the standard color tags, then custom tags, then "New Tag…". Shared by the file
/// list's context menu and the Get Info window.
@MainActor
enum TagMenu {
    /// `current` holds each URL's tags, in the same order. A tag every item has is checked and removed
    /// from all when chosen; otherwise it is added to all. `didChange` runs after every write attempt
    /// (also a failed one: earlier URLs may already be written).
    static func make(
        for urls: [URL], current: [[FileTag]], window: NSWindow?,
        didChange: (@MainActor () -> Void)? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string("tags.menu.title", "Tags"), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let standard = standardTags()
        let custom = customTags(current: current, excluding: standard)
        func addEntry(_ tag: FileTag) {
            let has = current.filter { $0.contains(tag) }.count
            let everyItem = has > 0 && has == current.count
            let entry = ActionMenuItem(tag.name, state: everyItem ? .on : has > 0 ? .mixed : .off) {
                apply(everyItem ? .remove(tag) : .add(tag), to: urls, window: window, didChange: didChange)
            }
            entry.image = dotImage(tag.color)
            menu.addItem(entry)
        }
        standard.forEach(addEntry)
        if !custom.isEmpty {
            menu.addItem(.separator())
            custom.forEach(addEntry)
        }
        menu.addItem(.separator())
        let known = standard + custom
        menu.addItem(ActionMenuItem(L10n.string("tags.action.newTag", "New Tag…")) {
            Task { @MainActor in
                guard let name = await askForTagName(window: window) else { return }
                // An existing tag of that name (case-insensitive) keeps its color.
                let tag = known.first { $0 == FileTag(name: name, color: .none) } ?? FileTag(name: name, color: .none)
                apply(.add(tag), to: urls, window: window, didChange: didChange)
            }
        })
        item.submenu = menu
        return item
    }

    /// Finder's seven color tags, named as the system localizes them (`fileLabels` is indexed by color
    /// number), in Finder's order.
    static func standardTags() -> [FileTag] {
        let names = NSWorkspace.shared.fileLabels
        return TagColor.finderOrder.compactMap { color in
            names.indices.contains(color.rawValue) ? FileTag(name: names[color.rawValue], color: color) : nil
        }
    }

    /// The system's color for a tag color; `.none` is clear.
    static func color(_ tagColor: TagColor) -> NSColor {
        guard tagColor != .none else { return .clear }
        let colors = NSWorkspace.shared.fileLabelColors
        return colors.indices.contains(tagColor.rawValue) ? colors[tagColor.rawValue] : .clear
    }

    /// A 12 pt dot for menus; an uncolored tag gets an outlined circle.
    static func dotImage(_ tagColor: TagColor) -> NSImage {
        let fill = color(tagColor)
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if tagColor == .none {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                fill.setFill()
                path.fill()
            }
            return true
        }
        return image
    }

    /// The custom (non-standard) tags offered in the menu: the catalog's (sorted by name), then any others
    /// on the items themselves, in order of first appearance. A tag on the items keeps its own color when
    /// the catalog has none for it.
    private static func customTags(current: [[FileTag]], excluding standard: [FileTag]) -> [FileTag] {
        let onItems = Array(current.joined())
        var seen = Set(standard)
        var result: [FileTag] = []
        for tag in TagCatalog.shared.tags where seen.insert(tag).inserted {
            let own = onItems.first { $0 == tag }
            result.append(tag.color == .none && own != nil ? own! : tag)
        }
        for tag in onItems where seen.insert(tag).inserted {
            result.append(tag)
        }
        return result
    }

    private static func apply(
        _ change: TagChange, to urls: [URL], window: NSWindow?, didChange: (@MainActor () -> Void)?
    ) {
        Task { @MainActor in
            do {
                try await TagStore.setTags(change, on: urls)
                // The catalog shows a newly used tag (and its color) at once.
                if case .add(let tag) = change { TagCatalog.shared.noteUsed(tag) }
            } catch {
                let alert = NSAlert(error: error)
                if let window, window.isVisible, window.attachedSheet == nil {
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } else {
                    alert.runModal()
                }
            }
            didChange?()
        }
    }

    /// Asks for a new tag's name; nil when cancelled or empty.
    private static func askForTagName(window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.string("tags.new.title", "New Tag")
        alert.informativeText = L10n.string("tags.new.message", "Enter a name for the new tag.")
        alert.addButton(withTitle: L10n.string("tags.new.add", "Add"))
        alert.addButton(withTitle: L10n.string("tags.prompt.cancel", "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L10n.string("tags.prompt.placeholder", "Tag name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response: NSApplication.ModalResponse
        if let window, window.isVisible, window.attachedSheet == nil {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        // A pasted newline would split the xattr entry: control characters become spaces.
        let name = TagStore.sanitizedName(field.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !name.isEmpty else { return nil }
        return name
    }
}
