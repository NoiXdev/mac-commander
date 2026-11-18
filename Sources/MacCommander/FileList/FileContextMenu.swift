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
        model: BrowserModel, settings: ViewSettingsStore, clipboard: FileClipboard, window: NSWindow?,
        openInfo: @escaping (URL) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Inside an archive (read-only): Extract All… replaces New, Paste and Get Info.
        let archive = model.archiveLocation?.archive
        if let archive {
            menu.addItem(ActionMenuItem(String(localized: "Extract All…")) {
                Task { @MainActor in
                    guard
                        let destination = await FileActions.chooseExtractionFolder(
                            startingAt: archive.deletingLastPathComponent(), window: window)
                    else { return }
                    await FileActions.extractAll(archive, into: destination, model: model, window: window)
                }
            })
        } else {
            addNewItemActions(to: menu, model: model, in: nil)
            menu.addItem(pasteItem(into: model.currentURL, model: model, clipboard: clipboard, window: window))
        }
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
        guard archive == nil else { return menu }
        menu.addItem(.separator())
        let folderURL = model.currentURL
        menu.addItem(ActionMenuItem(String(localized: "Get Info")) { FileActions.getInfo([folderURL], open: openInfo) })
        return menu
    }

    /// Right-click on rows. `all` are the clicked row, or the whole selection if it contains it; `items` are
    /// those without rows inside a selected folder. Duplicate, Copy, Cut, Move to Trash and Compress act on
    /// `items`, so a folder selected with its expanded contents is handled once; the rest go by `all`.
    static func forItems(
        _ items: [FileItem], all: [FileItem], model: BrowserModel, settings: ViewSettingsStore,
        clipboard: FileClipboard, window: NSWindow?, openInfo: @escaping (URL) -> Void,
        archiveQuickLook: @escaping @MainActor () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard !items.isEmpty else { return menu }

        let urls = all.map(\.url)
        menu.addItem(ActionMenuItem(String(localized: "Open")) {
            // Like ⌘↓: a single item opens (folders navigate); with several, only the files open.
            let toOpen = all.count == 1 ? all : all.filter { !$0.isDirectory }
            Task { @MainActor in await FileActions.open(toOpen, model: model, window: window) }
        })
        let quickLookTitle =
            all.count == 1
            ? String(localized: "Quick Look “\(all[0].name)”")
            : String(localized: "Quick Look \(all.count) items")
        if let location = model.archiveLocation {
            // Entries inside an archive (read-only): Open, Quick Look and the extract actions only. The
            // right-click selected exactly these items; Quick Look extracts their files first.
            menu.addItem(ActionMenuItem(quickLookTitle) { archiveQuickLook() })
            menu.addItem(.separator())
            addExtractEntriesActions(to: menu, entries: all, archive: location.archive, model: model, window: window)
            return menu
        }
        if all.count == 1, !all[0].isDirectory {
            addArchiveFileActions(to: menu, file: all[0], model: model, window: window)
        }
        menu.addItem(OpenWithMenu.make(for: urls))
        // The right-click selected exactly these items, so the panel previews them.
        menu.addItem(ActionMenuItem(quickLookTitle) { QuickLookController.showPanel() })
        menu.addItem(.separator())

        if all.count == 1 {
            let url = all[0].url
            // The list starts inline editing for `pendingRename`.
            menu.addItem(ActionMenuItem(String(localized: "Rename")) { model.pendingRename = url })
        }
        menu.addItem(ActionMenuItem(String(localized: "Duplicate")) {
            Task { @MainActor in await FileActions.duplicate(items, model: model, window: window) }
        })
        menu.addItem(.separator())

        let folder = all.count == 1 && all[0].isDirectory ? all[0].url : nil
        menu.addItem(ActionMenuItem(String(localized: "Copy")) { FileActions.copy(items, clipboard: clipboard) })
        menu.addItem(ActionMenuItem(String(localized: "Cut")) { FileActions.cut(items, clipboard: clipboard) })
        menu.addItem(pasteItem(into: folder ?? model.currentURL, model: model, clipboard: clipboard, window: window))
        menu.addItem(ActionMenuItem(String(localized: "Move to Trash")) {
            Task { @MainActor in await FileActions.moveToTrash(items, model: model, window: window) }
        })
        menu.addItem(.separator())

        // Inline-expanded rows can mix parents; compress needs one.
        if Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL }).count == 1 {
            let title =
                items.count == 1
                ? String(localized: "Compress “\(items[0].name)”")
                : String(localized: "Compress \(items.count) Items")
            menu.addItem(ActionMenuItem(title) {
                Task { @MainActor in await FileActions.compress(items, model: model, window: window) }
            })
            menu.addItem(.separator())
        }

        menu.addItem(TagMenu.make(for: urls, current: all.map(\.tags), window: window) {
            tagsDidChange(in: urls, model: model)
        })
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem(String(localized: "Get Info")) { FileActions.getInfo(urls, open: openInfo) })
        menu.addItem(ActionMenuItem(String(localized: "Copy Path")) { FileActions.copyPath(all) })
        menu.addItem(ActionMenuItem(String(localized: "Reveal in Finder")) { FileActions.revealInFinder(urls) })
        menu.addItem(.separator())

        addNewItemActions(to: menu, model: model, in: folder)
        return menu
    }

    /// For an archive file (outside an archive), after Open: Extract All Here and Open with Archive Utility for
    /// pure archives; Browse Contents for containers such as `.docx` (pure archives browse on Open), but not
    /// for packages (e.g. a `.pages` or `.key` document saved as a folder).
    private static func addArchiveFileActions(
        to menu: NSMenu, file: FileItem, model: BrowserModel, window: NSWindow?
    ) {
        let url = file.url
        if ArchiveFormats.isArchive(url) {
            menu.addItem(ActionMenuItem(String(localized: "Extract All Here")) {
                Task { @MainActor in
                    await FileActions.extractAll(url, into: url.deletingLastPathComponent(), model: model, window: window)
                }
            })
            menu.addItem(ActionMenuItem(String(localized: "Open with Archive Utility")) {
                FileActions.openWithArchiveUtility(url)
            })
        } else if ArchiveFormats.isBrowsable(url), !file.isPackage {
            menu.addItem(ActionMenuItem(String(localized: "Browse Contents")) {
                Task { @MainActor in await model.browseContents(file) }
            })
        }
    }

    /// For entries inside `archive`: Extract to the archive's own folder, or to a chosen one. A folder
    /// selected along with rows of its expanded contents is extracted once.
    private static func addExtractEntriesActions(
        to menu: NSMenu, entries items: [FileItem], archive: URL, model: BrowserModel, window: NSWindow?
    ) {
        // Computed when chosen, not while the menu is built (pure string work on the paths).
        let urls = items.map(\.url)
        let entries = { PathUtilities.topLevel(urls).compactMap { ArchivePath.inner(of: $0, in: archive) } }
        let parent = archive.deletingLastPathComponent()
        // The folder name at once; its Finder name follows from off the main actor (it may be on a network volume).
        let extractHere = ActionMenuItem(String(localized: "Extract to “\(parent.lastPathComponent)”")) {
            Task { @MainActor in
                await FileActions.extract(entries(), from: archive, into: parent, model: model, window: window)
            }
        }
        menu.addItem(extractHere)
        Task { @MainActor in
            let parentName = await PathQueries.displayName(parent)
            extractHere.title = String(localized: "Extract to “\(parentName)”")
        }
        menu.addItem(ActionMenuItem(String(localized: "Extract To…")) {
            Task { @MainActor in
                guard let destination = await FileActions.chooseExtractionFolder(startingAt: parent, window: window)
                else { return }
                await FileActions.extract(entries(), from: archive, into: destination, model: model, window: window)
            }
        })
    }

    /// The folder watcher only sees changes to the folder itself, not to its files' extended attributes,
    /// so a tag change is announced like a file operation's: the model re-lists the current folder (local
    /// or network) and the list re-lists the affected inline-expanded subfolders.
    private static func tagsDidChange(in urls: [URL], model: BrowserModel) {
        let folders = urls.map { $0.deletingLastPathComponent().standardizedFileURL }
        NotificationCenter.default.post(
            name: FileOperationCenter.foldersDidChange, object: model.operations, userInfo: ["folders": folders])
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
