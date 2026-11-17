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
    static func forEmptySpace(model: BrowserModel, settings: ViewSettingsStore) -> NSMenu {
        let menu = NSMenu()
        addNewItemActions(to: menu, model: model, in: nil)
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
        return menu
    }

    /// Right-click on rows. `items` are the clicked row, or the whole selection if it contains it.
    static func forItems(_ items: [FileItem], model: BrowserModel, settings: ViewSettingsStore) -> NSMenu {
        let menu = NSMenu()
        guard !items.isEmpty else { return menu }

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
        // The right-click selected exactly these items, so the panel previews them.
        menu.addItem(ActionMenuItem(quickLookTitle) { QuickLookController.showPanel() })
        if items.count == 1 {
            let url = items[0].url
            // The list starts inline editing for `pendingRename`.
            menu.addItem(ActionMenuItem(String(localized: "Rename")) { model.pendingRename = url })
        }
        menu.addItem(.separator())

        let folder = items.count == 1 && items[0].isDirectory ? items[0].url : nil
        addNewItemActions(to: menu, model: model, in: folder)
        return menu
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
