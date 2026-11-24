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
        openInfo: @escaping (URL) -> Void, terminalApp: @escaping () -> TerminalApp?
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Inside an archive (read-only): Extract All… replaces New, Paste and Get Info.
        let archive = model.archiveLocation?.archive
        if let archive {
            menu.addItem(ActionMenuItem(L10n.string("fileList.menu.extractAll", "Extract All…")) {
                Task { @MainActor in
                    guard
                        let destination = await FileActions.chooseExtractionFolder(
                            startingAt: archive.deletingLastPathComponent(), window: window)
                    else { return }
                    await FileActions.extractAll(archive, into: destination, model: model, window: window)
                }
            })
        } else {
            // While a search is shown, new items and pasted ones would land in the hidden current folder.
            addNewItemActions(to: menu, model: model, in: nil, isEnabled: !model.isSearching)
            let paste = pasteItem(into: model.currentURL, model: model, clipboard: clipboard, window: window)
            if model.isSearching { paste.isEnabled = false }
            menu.addItem(paste)
        }
        menu.addItem(.separator())

        let sortItem = NSMenuItem(title: L10n.string("fileList.menu.sortBy", "Sort By"), action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        // Location only while searching; a stored Location sort shows as Name outside a search.
        let stored = settings.settings.sortOrder.column
        let current = stored == .location && !model.isSearching ? FileColumn.name : stored
        for column in FileColumn.allCases where column != .location || model.isSearching {
            sortMenu.addItem(ActionMenuItem(column.title, state: column == current ? .on : .off) {
                var order = settings.settings.sortOrder
                guard current != column else { return }
                order.column = column
                order.ascending = true
                settings.settings.sortOrder = order
            })
        }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)

        menu.addItem(ActionMenuItem(
            L10n.string("fileList.menu.showHiddenFiles", "Show Hidden Files"), state: settings.settings.showHiddenFiles ? .on : .off
        ) {
            settings.settings.showHiddenFiles.toggle()
        })
        menu.addItem(ActionMenuItem(
            L10n.string("fileList.menu.showCheckboxColumn", "Show Checkbox Column"), state: settings.settings.showCheckboxColumn ? .on : .off
        ) {
            settings.settings.showCheckboxColumn.toggle()
        })
        guard archive == nil else { return menu }
        menu.addItem(.separator())
        let folderURL = model.currentURL
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.getInfo", "Get Info")) { FileActions.getInfo([folderURL], open: openInfo) })
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.copyFolderPath", "Copy Folder Path")) { FileActions.copyPaths([folderURL]) })
        // During a search the current folder is hidden behind the results, but it's still where the user is.
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.openInTerminal", "Open in Terminal")) {
            FileActions.openInTerminal([folderURL], chosen: terminalApp(), window: window)
        })
        return menu
    }

    /// Right-click on rows. `all` are the clicked row, or the whole selection if it contains it; `items` are
    /// those without rows inside a selected folder. Duplicate, Copy, Cut, Move to Trash and Compress act on
    /// `items`, so a folder selected with its expanded contents is handled once; the rest (Convert included:
    /// any folder hides it) go by `all`.
    static func forItems(
        _ items: [FileItem], all: [FileItem], model: BrowserModel, settings: ViewSettingsStore,
        clipboard: FileClipboard, window: NSWindow?, openInfo: @escaping (URL) -> Void,
        terminalApp: @escaping () -> TerminalApp?, paneCommands: PaneCommands? = nil, archiveQuickLook: @escaping @MainActor () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard !items.isEmpty else { return menu }

        let urls = all.map(\.url)
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.open", "Open")) {
            // Like ⌘↓: a single item opens (folders navigate); with several, only the files open.
            let toOpen = all.count == 1 ? all : all.filter { !$0.isDirectory }
            Task { @MainActor in await FileActions.open(toOpen, model: model, window: window) }
        })
        let quickLookTitle =
            all.count == 1
            ? L10n.format("fileList.menu.quickLookOne", "Quick Look “%@”", all[0].name)
            : L10n.plural("fileList.menu.quickLook", count: all.count, one: "Quick Look 1 item", other: "Quick Look %lld items")
        if let location = model.archiveLocation {
            // Entries inside an archive (read-only): Open, Quick Look and the extract actions only. The
            // right-click selected exactly these items; Quick Look extracts their files first.
            menu.addItem(ActionMenuItem(quickLookTitle) { archiveQuickLook() })
            menu.addItem(.separator())
            addExtractEntriesActions(to: menu, entries: all, archive: location.archive, model: model, window: window)
            if let paneCommands {
                menu.addItem(.separator())
                addPaneTransferActions(to: menu, commands: paneCommands, isInArchive: true)
            }
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
            menu.addItem(ActionMenuItem(L10n.string("fileList.menu.rename", "Rename")) { model.pendingRename = url })
        }
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.duplicate", "Duplicate")) {
            Task { @MainActor in await FileActions.duplicate(items, model: model, window: window) }
        })
        menu.addItem(.separator())

        let folder = all.count == 1 && all[0].isDirectory ? all[0].url : nil
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.copy", "Copy")) { FileActions.copy(items, clipboard: clipboard) })
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.cut", "Cut")) { FileActions.cut(items, clipboard: clipboard) })
        if let paneCommands { addPaneTransferActions(to: menu, commands: paneCommands, isInArchive: false) }
        let paste = pasteItem(into: folder ?? model.currentURL, model: model, clipboard: clipboard, window: window)
        if folder == nil, model.isSearching { paste.isEnabled = false }
        menu.addItem(paste)
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.moveToTrash", "Move to Trash")) {
            Task { @MainActor in await FileActions.moveToTrash(items, model: model, window: window) }
        })
        menu.addItem(.separator())

        // Inline-expanded rows can mix parents; compress needs one.
        if Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL }).count == 1 {
            let title =
                items.count == 1
                ? L10n.format("fileList.menu.compressOne", "Compress “%@”", items[0].name)
                : L10n.plural("fileList.menu.compress", count: items.count, one: "Compress 1 Item", other: "Compress %lld Items")
            menu.addItem(ActionMenuItem(title) {
                Task { @MainActor in await FileActions.compress(items, model: model, window: window) }
            })
            menu.addItem(.separator())
        }
        if let convert = ConvertActions.menuItem(for: all, model: model, window: window) {
            menu.addItem(convert)
            menu.addItem(.separator())
        }

        menu.addItem(TagMenu.make(for: urls, current: all.map(\.tags), window: window) {
            tagsDidChange(in: urls, model: model)
        })
        menu.addItem(.separator())

        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.getInfo", "Get Info")) { FileActions.getInfo(urls, open: openInfo) })
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.copyPath", "Copy Path")) { FileActions.copyPath(all) })
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.revealInFinder", "Reveal in Finder")) { FileActions.revealInFinder(urls) })
        let terminalFolders = TerminalApp.folders(for: all)
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.openInTerminal", "Open in Terminal")) {
            FileActions.openInTerminal(terminalFolders, chosen: terminalApp(), window: window)
        })
        menu.addItem(.separator())

        addNewItemActions(to: menu, model: model, in: folder, isEnabled: folder != nil || !model.isSearching)
        return menu
    }

    /// Copy / Move to Other Pane (dual-pane mode): open the confirmation sheet. Copy extracts archive entries;
    /// Move is disabled for them (archives are read-only).
    private static func addPaneTransferActions(to menu: NSMenu, commands: PaneCommands, isInArchive: Bool) {
        let canTransfer = commands.canTransfer()
        let copy = ActionMenuItem(L10n.string("fileList.menu.copyToOtherPane", "Copy to Other Pane")) {
            if !commands.requestTransfer(false) { NSSound.beep() }
        }
        copy.isEnabled = canTransfer
        let move = ActionMenuItem(L10n.string("fileList.menu.moveToOtherPane", "Move to Other Pane")) {
            if !commands.requestTransfer(true) { NSSound.beep() }
        }
        move.isEnabled = canTransfer && !isInArchive
        menu.addItem(copy)
        menu.addItem(move)
    }

    /// For an archive file (outside an archive), after Open: Extract All Here and Open with Archive Utility for
    /// pure archives; Browse Contents for containers such as `.docx` (pure archives browse on Open), but not
    /// for packages (e.g. a `.pages` or `.key` document saved as a folder).
    private static func addArchiveFileActions(
        to menu: NSMenu, file: FileItem, model: BrowserModel, window: NSWindow?
    ) {
        let url = file.url
        if ArchiveFormats.isArchive(url) {
            menu.addItem(ActionMenuItem(L10n.string("fileList.menu.extractAllHere", "Extract All Here")) {
                Task { @MainActor in
                    await FileActions.extractAll(url, into: url.deletingLastPathComponent(), model: model, window: window)
                }
            })
            menu.addItem(ActionMenuItem(L10n.string("fileList.menu.openWithArchiveUtility", "Open with Archive Utility")) {
                FileActions.openWithArchiveUtility(url)
            })
        } else if ArchiveFormats.isBrowsable(url), !file.isPackage {
            menu.addItem(ActionMenuItem(L10n.string("fileList.menu.browseContents", "Browse Contents")) {
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
        let extractHere = ActionMenuItem(L10n.format("fileList.menu.extractToFolder", "Extract to “%@”", parent.lastPathComponent)) {
            Task { @MainActor in
                await FileActions.extract(entries(), from: archive, into: parent, model: model, window: window)
            }
        }
        menu.addItem(extractHere)
        Task { @MainActor in
            let parentName = await PathQueries.displayName(parent)
            extractHere.title = L10n.format("fileList.menu.extractToFolder", "Extract to “%@”", parentName)
        }
        menu.addItem(ActionMenuItem(L10n.string("fileList.menu.extractTo", "Extract To…")) {
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
        model.operations.announceChanged(folders: urls.map { $0.deletingLastPathComponent() })
    }

    /// Paste into `destination`; disabled while the clipboard is empty.
    private static func pasteItem(
        into destination: URL, model: BrowserModel, clipboard: FileClipboard, window: NSWindow?
    ) -> NSMenuItem {
        let item = ActionMenuItem(L10n.string("fileList.menu.paste", "Paste")) {
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
    private static func addNewItemActions(to menu: NSMenu, model: BrowserModel, in folder: URL?, isEnabled: Bool) {
        let newFolder = ActionMenuItem(L10n.string("fileList.menu.newFolder", "New Folder")) {
            Task { @MainActor in await BrowserActions.newFolder(model, in: folder) }
        }
        let newFile = ActionMenuItem(L10n.string("fileList.menu.newEmptyFile", "New Empty File")) {
            Task { @MainActor in await BrowserActions.newFile(model, in: folder) }
        }
        for item in [newFolder, newFile] {
            item.isEnabled = isEnabled
            menu.addItem(item)
        }
    }
}
