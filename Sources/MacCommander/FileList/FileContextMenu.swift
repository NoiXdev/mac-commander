import AppKit
import MacCommanderCore

/// A menu item that runs a closure. Context menus are built per click, so the closure captures
/// the click's targets directly.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.state = state
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        handler()
    }
}

/// The file list's context menus. Later plans append their items to the returned menus.
@MainActor
enum FileContextMenu {
    /// Right-click on empty space (spec 2.2.3).
    static func forEmptySpace(
        model: BrowserModel, settings: ViewSettingsStore, clipboard: FileClipboard, window: NSWindow?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addNewItemActions(to: menu, model: model, in: nil)
        menu.addItem(pasteItem(into: model.currentURL, model: model, clipboard: clipboard, window: window))
        menu.addItem(.separator())

        let sortItem = NSMenuItem(title: String(localized: "Sort By"), action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        let current = settings.settings.sortOrder
        for column in FileColumn.allCases {
            sortMenu.addItem(ActionMenuItem(column.title, state: column == current.column ? .on : .off) {
                var order = settings.settings.sortOrder
                guard order.column != column else { return }
                order.column = column
                order.ascending = true
                settings.settings.sortOrder = order
            })
        }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        menu.addItem(ActionMenuItem(
            String(localized: "Show Hidden Files"), state: settings.settings.showHiddenFiles ? .on : .off
        ) {
            settings.settings.showHiddenFiles.toggle()
        })
        menu.addItem(ActionMenuItem(
            String(localized: "Show Checkbox Column"), state: settings.settings.showCheckboxColumn ? .on : .off
        ) {
            settings.settings.showCheckboxColumn.toggle()
        })
        menu.addItem(.separator())
        let folderURL = model.currentURL
        menu.addItem(ActionMenuItem(String(localized: "Get Info")) { FileActions.getInfo([folderURL]) })
        return menu
    }

    /// Right-click on rows. `items` are the clicked row, or the whole selection if it contains it.
    static func forItems(
        _ items: [FileItem], model: BrowserModel, settings: ViewSettingsStore, clipboard: FileClipboard,
        window: NSWindow?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard !items.isEmpty else { return menu }

        let urls = items.map(\.url)
        menu.addItem(ActionMenuItem(String(localized: "Open")) {
            // Like ⌘↓: a single item opens (folders navigate); with several, only the files open.
            let toOpen = items.count == 1 ? items : items.filter { !$0.isDirectory }
            Task { @MainActor in
                for item in toOpen { await model.open(item) }
            }
        })
        let quickLookTitle =
            items.count == 1
            ? String(localized: "Quick Look “\(items[0].name)”")
            : String(localized: "Quick Look \(items.count) items")
        menu.addItem(OpenWithMenu.make(for: urls))
        // The right-click selected exactly these items, so the panel previews them.
        menu.addItem(ActionMenuItem(quickLookTitle) { QuickLookController.showPanel() })
        menu.addItem(.separator())

        if items.count == 1 {
            let url = items[0].url
            // The list starts inline editing for `pendingRename`.
            menu.addItem(ActionMenuItem(String(localized: "Rename")) { model.pendingRename = url })
        }
        menu.addItem(ActionMenuItem(String(localized: "Duplicate")) {
            Task { @MainActor in await FileActions.duplicate(items, model: model, window: window) }
        })
        menu.addItem(.separator())

        let folder = items.count == 1 && items[0].isDirectory ? items[0].url : nil
        menu.addItem(ActionMenuItem(String(localized: "Copy")) { FileActions.copy(items, clipboard: clipboard) })
        menu.addItem(ActionMenuItem(String(localized: "Cut")) { FileActions.cut(items, clipboard: clipboard) })
        menu.addItem(pasteItem(into: folder ?? model.currentURL, model: model, clipboard: clipboard, window: window))
        menu.addItem(ActionMenuItem(String(localized: "Move to Trash")) {
            Task { @MainActor in await FileActions.moveToTrash(items, model: model, window: window) }
        })
        menu.addItem(.separator())

        // Inline-expanded rows can mix parents; compress needs one.
        if Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL }).count == 1 {
            let title =
                items.count == 1
                ? String(localized: "Compress “\(items[0].name)”")
                : String(localized: "Compress \(items.count) Items")
            menu.addItem(ActionMenuItem(title) {
                Task { @MainActor in await FileActions.compress(items, model: model, window: window) }
            })
            menu.addItem(.separator())
        }

        menu.addItem(ActionMenuItem(String(localized: "Get Info")) { FileActions.getInfo(urls) })
        menu.addItem(ActionMenuItem(String(localized: "Copy Path")) { FileActions.copyPath(items) })
        menu.addItem(ActionMenuItem(String(localized: "Reveal in Finder")) { FileActions.revealInFinder(urls) })
        menu.addItem(.separator())

        addNewItemActions(to: menu, model: model, in: folder)
        return menu
    }

    /// Paste into `destination`; disabled while the clipboard is empty.
    private static func pasteItem(
        into destination: URL, model: BrowserModel, clipboard: FileClipboard, window: NSWindow?
    ) -> NSMenuItem {
        let item = ActionMenuItem(String(localized: "Paste")) {
            Task { @MainActor in
                await FileActions.paste(
                    into: destination, forceMove: false, model: model, clipboard: clipboard, window: window)
            }
        }
        item.isEnabled = !clipboard.fileURLs.isEmpty
        return item
    }

    /// New Folder and New Empty File, in `folder` (nil = the current folder). The list expands
    /// the folder when the new item's rename starts.
    private static func addNewItemActions(to menu: NSMenu, model: BrowserModel, in folder: URL?) {
        menu.addItem(ActionMenuItem(String(localized: "New Folder")) {
            Task { @MainActor in await BrowserActions.newFolder(model, in: folder) }
        })
        menu.addItem(ActionMenuItem(String(localized: "New Empty File")) {
            Task { @MainActor in await BrowserActions.newFile(model, in: folder) }
        })
    }
}
