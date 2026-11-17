import AppKit
import MacCommanderCore
import Observation
import SwiftUI

/// One outline row. A reference type, so `NSOutlineView` sees a stable identity per URL across
/// updates. URLs are the loader's spelling (from `model.items` / `model.children(of:)`).
@MainActor
final class FileNode {
    let url: URL
    var item: FileItem
    weak var parent: FileNode?
    /// Loaded children of a folder; nil until loaded. Cleared on reload unless the folder is expanded.
    var children: [FileNode]?
    /// False once the node left the tree; late child listings for it are dropped.
    private(set) var isAttached = true
    var loadTask: Task<Void, Never>?

    init(item: FileItem, parent: FileNode?) {
        url = item.url
        self.item = item
        self.parent = parent
    }

    func detach() {
        isAttached = false
        loadTask?.cancel()
        loadTask = nil
        children?.forEach { $0.detach() }
    }
}

/// The file list: a view-based `NSOutlineView` showing `model.items`, with inline folder expansion,
/// persistent columns (`settings.columnLayout`) and a checkbox column mirroring the selection.
final class FileListController: NSViewController {
    let model: BrowserModel
    let settings: ViewSettingsStore

    private(set) var outlineView = FileOutlineView()
    private let scrollView = NSScrollView()
    private var errorHost: NSHostingView<LoadErrorView>?

    var roots: [FileNode] = []
    /// Folders the user expanded, restored by URL after reloads.
    private var expandedURLs: Set<URL> = []
    private var displayedFolder: URL?
    /// The selection last exchanged with the model; avoids redundant row scans.
    private var syncedSelection: Set<URL> = []
    /// > 0 while the controller changes rows or selection itself, so callbacks don't write back.
    private var changeDepth = 0
    private var isApplyingChanges: Bool { changeDepth > 0 }
    /// True while columns are adjusted to the settings, so resize/move callbacks don't write back.
    private var isApplyingLayout = false
    private let icons = FileIconProvider()
    private var iconPassScheduled = false
    /// Inline rename state (see `FileListController+Rename.swift`).
    var rename = InlineRenameState()

    /// Above this many inserted/removed/changed rows, a reload is cheaper than row animations.
    private static let maxIncrementalChanges = 500

    init(model: BrowserModel, settings: ViewSettingsStore) {
        self.model = model
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - View setup

    override func loadView() {
        let container = NSView()
        configureOutline()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        applySettings()
        applyItems()
        applyLoadError()
        observeItems()
        observeCurrentFolder()
        observeSelection()
        observeLoadError()
        observeSettings()
        observePendingRename()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(outlineView)
    }

    private func configureOutline() {
        let outline = outlineView
        outline.headerView = NSTableHeaderView()
        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        // A header click must never select a column: that would clear the row selection.
        outline.allowsColumnSelection = false
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.autosaveExpandedItems = false
        outline.indentationPerLevel = 14
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: true)

        makeColumns()

        let headerMenu = NSMenu()
        headerMenu.delegate = self
        outline.headerView?.menu = headerMenu

        outline.target = self
        outline.doubleAction = #selector(openClickedRow)
        outline.onOpenSelection = { [weak self] in self?.openSelection() }
        outline.onGoUp = { [weak self] in
            guard let model = self?.model else { return }
            Task { await model.goUp() }
        }
        outline.onRename = { [weak self] in self?.renameSelection() }
        outline.onToggleQuickLook = { [weak self] in self?.toggleQuickLook() }
        outline.contextMenu = { [weak self] row in self?.contextMenu(forRow: row) }
        outline.allowsInteraction = { [weak self] in self?.showsCurrentFolder ?? false }
        outline.quickLook = QuickLookController(keyTarget: outline) { [weak self] in
            self?.selectedNodes.map(\.url) ?? []
        }
        outline.dataSource = self
        outline.delegate = self
    }

    private func makeColumns() {
        let checkbox = NSTableColumn(identifier: .checkboxColumn)
        checkbox.headerCell = CheckboxHeaderCell(textCell: "")
        checkbox.width = 24
        checkbox.minWidth = 24
        checkbox.maxWidth = 24
        checkbox.resizingMask = []
        outlineView.addTableColumn(checkbox)

        for state in settings.settings.columnLayout.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(state.column))
            column.title = state.column.title
            column.minWidth = state.column == .name ? 100 : 40
            column.width = CGFloat(state.width)
            column.resizingMask = .userResizingMask
            column.isHidden = state.column != .name && !state.isVisible
            if state.column == .size { column.headerCell.alignment = .right }
            outlineView.addTableColumn(column)
            if state.column == .name { outlineView.outlineTableColumn = column }
        }
    }

    private var checkboxColumn: NSTableColumn? {
        outlineView.tableColumn(withIdentifier: .checkboxColumn)
    }

    // MARK: - Observation

    private func observeItems() {
        withObservationTracking {
            _ = model.items
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeItems()
                self?.applyItems()
            }
        }
    }

    /// Navigation changes `currentURL` before the new items arrive: clear the old rows at once,
    /// so nothing from the previous folder can be selected or opened meanwhile.
    private func observeCurrentFolder() {
        withObservationTracking {
            _ = model.currentURL
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeCurrentFolder()
                self?.currentFolderDidChange()
            }
        }
    }

    private func currentFolderDidChange() {
        guard model.currentURL != displayedFolder, displayedFolder != nil || !roots.isEmpty else { return }
        endRename(commit: true)
        outlineView.quickLook?.folderDidChange()
        displayedFolder = nil
        roots.forEach { $0.detach() }
        roots = []
        expandedURLs = []
        applyingChanges { outlineView.reloadData() }
        updateCheckboxStates()
    }

    /// False while the rows still belong to a folder other than `model.currentURL`.
    var showsCurrentFolder: Bool {
        displayedFolder == model.currentURL
    }

    private func observeSelection() {
        withObservationTracking {
            _ = model.selection
        } onChange: { [weak self] in
            Task { @MainActor in self?.selectionDidChangeInModel() }
        }
    }

    private func selectionDidChangeInModel() {
        observeSelection()
        if model.selection != syncedSelection { syncSelectionFromModel() }
    }

    private func observeLoadError() {
        withObservationTracking {
            _ = model.loadError
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeLoadError()
                self?.applyLoadError()
            }
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.settings
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeSettings()
                self?.applySettings()
            }
        }
    }

    // MARK: - Load error

    private func applyLoadError() {
        guard let error = model.loadError else {
            errorHost?.isHidden = true
            scrollView.isHidden = false
            return
        }
        if let errorHost {
            errorHost.rootView = LoadErrorView(error: error)
            errorHost.isHidden = false
        } else {
            let host = NSHostingView(rootView: LoadErrorView(error: error))
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.topAnchor.constraint(equalTo: view.topAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            errorHost = host
        }
        scrollView.isHidden = true
    }

    // MARK: - Items

    /// Shows `model.items`. A new folder resets the tree; the same folder is diffed by URL, keeping
    /// scroll position, selection and expansion. Loaded subfolders are re-listed if expanded and
    /// dropped from the cache otherwise.
    private func applyItems() {
        let items = model.items
        let folder = model.currentURL
        if folder != displayedFolder {
            displayedFolder = folder
            roots.forEach { $0.detach() }
            expandedURLs = []
            roots = items.map { FileNode(item: $0, parent: nil) }
            applyingChanges { outlineView.reloadData() }
            if outlineView.numberOfRows > 0 { outlineView.scrollRowToVisible(0) }
            syncSelectionFromModel()
            startPendingRename()
            return
        }
        applyingChanges {
            apply(items, in: nil)
            restoreExpansion(in: roots)
        }
        refreshLoadedFolders(in: roots)
        syncSelectionFromModel()
        repairRenameSession()
        startPendingRename()
    }

    /// Replaces the children of `parent` (nil = root) by `items`, reusing nodes by URL. Uses row
    /// inserts/removals when the order of the remaining rows is unchanged, otherwise a reload.
    private func apply(_ items: [FileItem], in parent: FileNode?) {
        let old = parent.map { $0.children ?? [] } ?? roots
        var oldByURL: [URL: FileNode] = [:]
        oldByURL.reserveCapacity(old.count)
        for node in old { oldByURL[node.url] = node }

        var newNodes: [FileNode] = []
        newNodes.reserveCapacity(items.count)
        var inserted = IndexSet()
        var changed: [FileNode] = []
        for (index, item) in items.enumerated() {
            if let node = oldByURL.removeValue(forKey: item.url) {
                if node.item != item {
                    node.item = item
                    changed.append(node)
                }
                newNodes.append(node)
            } else {
                newNodes.append(FileNode(item: item, parent: parent))
                inserted.insert(index)
            }
        }
        // What's left in `oldByURL` is gone.
        var removed = IndexSet()
        for (index, node) in old.enumerated() where oldByURL[node.url] === node {
            removed.insert(index)
            node.detach()
        }
        let keptOld = old.enumerated().lazy.filter { !removed.contains($0.offset) }.map(\.element)
        let keptNew = newNodes.enumerated().lazy.filter { !inserted.contains($0.offset) }.map(\.element)
        let orderPreserved = keptOld.elementsEqual(keptNew, by: ===)

        if let parent { parent.children = newNodes } else { roots = newNodes }

        let changeCount = inserted.count + removed.count + changed.count
        if old.isEmpty || !orderPreserved || changeCount > Self.maxIncrementalChanges {
            reload(parent)
            return
        }
        if !inserted.isEmpty || !removed.isEmpty {
            outlineView.beginUpdates()
            outlineView.removeItems(at: removed, inParent: parent, withAnimation: [])
            outlineView.insertItems(at: inserted, inParent: parent, withAnimation: [])
            outlineView.endUpdates()
        }
        for node in changed { outlineView.reloadItem(node) }
    }

    private func reload(_ parent: FileNode?) {
        if let parent {
            outlineView.reloadItem(parent, reloadChildren: true)
        } else {
            outlineView.reloadData()
        }
    }

    /// Re-expands folders in `expandedURLs` among `nodes` (recursively), listing them if needed.
    private func restoreExpansion(in nodes: [FileNode]) {
        guard !expandedURLs.isEmpty else { return }
        for node in nodes where expandedURLs.contains(node.url) {
            if let children = node.children {
                if !outlineView.isItemExpanded(node) { outlineView.expandItem(node) }
                restoreExpansion(in: children)
            } else if node.loadTask == nil {
                loadChildren(of: node, expand: true)
            }
        }
    }

    /// After a reload: re-lists expanded folders and clears the cached children of collapsed ones.
    private func refreshLoadedFolders(in nodes: [FileNode]) {
        for node in nodes {
            guard let children = node.children else { continue }
            if outlineView.isItemExpanded(node) {
                loadChildren(of: node, expand: false)
                refreshLoadedFolders(in: children)
            } else {
                children.forEach { $0.detach() }
                node.children = nil
                applyingChanges { outlineView.reloadItem(node, reloadChildren: true) }
            }
        }
    }

    /// Lists a folder's children through the model, then shows them (and expands if asked).
    func loadChildren(of node: FileNode, expand: Bool) {
        node.loadTask?.cancel()
        node.loadTask = Task { [weak self, model] in
            let items: [FileItem]
            do {
                items = try await model.children(of: node.url)
            } catch {
                // An unreadable subfolder expands to nothing, like in Finder.
                items = []
            }
            guard !Task.isCancelled, node.isAttached, let self else { return }
            node.loadTask = nil
            didLoadChildren(items, of: node, expand: expand)
        }
    }

    private func didLoadChildren(_ items: [FileItem], of node: FileNode, expand: Bool) {
        applyingChanges {
            if node.children == nil {
                node.children = items.map { FileNode(item: $0, parent: node) }
                outlineView.reloadItem(node, reloadChildren: true)
            } else {
                apply(items, in: node)
            }
            if expand {
                expandedURLs.insert(node.url)
                outlineView.expandItem(node)
            }
            if outlineView.isItemExpanded(node), let children = node.children {
                restoreExpansion(in: children)
            }
        }
        syncSelectionFromModel()
        repairRenameSession()
        startPendingRename()
    }

    private func applyingChanges(_ body: () -> Void) {
        changeDepth += 1
        defer { changeDepth -= 1 }
        body()
    }

    func node(atRow row: Int) -> FileNode? {
        outlineView.item(atRow: row) as? FileNode
    }

    /// The selected rows' nodes, in row order.
    var selectedNodes: [FileNode] {
        outlineView.selectedRowIndexes.compactMap { node(atRow: $0) }
    }

    // MARK: - Selection

    /// Selects the visible rows whose URLs are in `model.selection`.
    private func syncSelectionFromModel() {
        let wanted = model.selection
        syncedSelection = wanted
        var rows = IndexSet()
        if !wanted.isEmpty {
            for row in 0..<outlineView.numberOfRows {
                if let node = node(atRow: row), wanted.contains(node.url) { rows.insert(row) }
            }
        }
        if rows != outlineView.selectedRowIndexes {
            applyingChanges { outlineView.selectRowIndexes(rows, byExtendingSelection: false) }
        }
        updateCheckboxStates()
    }

    private func writeSelectionToModel() {
        guard showsCurrentFolder else { return }
        var urls = Set<URL>()
        for row in outlineView.selectedRowIndexes {
            if let node = node(atRow: row) { urls.insert(node.url) }
        }
        syncedSelection = urls
        if model.selection != urls { model.selection = urls }
    }

    /// Updates the header checkbox and the visible row checkboxes from `selectedRowIndexes`.
    private func updateCheckboxStates() {
        let selected = outlineView.selectedRowIndexes
        guard let column = checkboxColumn else { return }
        if let header = column.headerCell as? CheckboxHeaderCell {
            let state: NSControl.StateValue =
                selected.isEmpty ? .off : (selected.count == outlineView.numberOfRows ? .on : .mixed)
            if header.checkState != state {
                header.checkState = state
                outlineView.headerView?.needsDisplay = true
            }
        }
        guard !column.isHidden else { return }
        let columnIndex = outlineView.column(withIdentifier: .checkboxColumn)
        guard let visible = Range(outlineView.rows(in: outlineView.visibleRect)) else { return }
        for row in visible {
            if let cell = outlineView.view(atColumn: columnIndex, row: row, makeIfNecessary: false)
                as? CheckboxCellView
            {
                cell.checkbox.state = selected.contains(row) ? .on : .off
            }
        }
    }

    private func toggleSelectAll() {
        if outlineView.numberOfRows > 0, outlineView.selectedRowIndexes.count == outlineView.numberOfRows {
            outlineView.deselectAll(nil)
        } else {
            outlineView.selectAll(nil)
        }
    }

    // MARK: - Opening

    @objc private func openClickedRow() {
        let row = outlineView.clickedRow
        guard showsCurrentFolder, row >= 0, let node = node(atRow: row) else { return }
        let item = node.item
        Task { await model.open(item) }
    }

    /// ⌘↓: a single item opens (folders navigate); with several, only the files are opened.
    private func openSelection() {
        guard showsCurrentFolder else { return }
        let items = outlineView.selectedRowIndexes.compactMap { node(atRow: $0)?.item }
        guard !items.isEmpty else { return }
        let toOpen = items.count == 1 ? items : items.filter { !$0.isDirectory }
        Task {
            for item in toOpen { await model.open(item) }
        }
    }

    // MARK: - Columns

    private func applySettings() {
        applyColumnLayout()
        applySortIndicator()
        updateCheckboxStates()
    }

    /// Moves, resizes and hides columns to match the stored layout (checkbox column stays first).
    private func applyColumnLayout() {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        let current = settings.settings
        if let checkbox = checkboxColumn, checkbox.isHidden == current.showCheckboxColumn {
            checkbox.isHidden = !current.showCheckboxColumn
        }
        for (offset, state) in current.columnLayout.columns.enumerated() {
            let target = offset + 1
            let index = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(state.column))
            guard index >= 0 else { continue }
            if index != target, target < outlineView.numberOfColumns {
                outlineView.moveColumn(index, toColumn: target)
            }
            guard let column = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(state.column))
            else { continue }
            if abs(Double(column.width) - state.width) > 0.5 { column.width = CGFloat(state.width) }
            let hidden = state.column != .name && !state.isVisible
            if column.isHidden != hidden { column.isHidden = hidden }
        }
    }

    /// Writes the outline's column order, widths and visibility to the settings.
    private func saveColumnLayout() {
        guard !isApplyingLayout else { return }
        let columns = outlineView.tableColumns.compactMap { column -> ColumnState? in
            guard let fileColumn = FileColumn(rawValue: column.identifier.rawValue) else { return nil }
            return ColumnState(column: fileColumn, width: Double(column.width), isVisible: !column.isHidden)
        }
        let layout = ColumnLayout(columns: columns)
        if layout != settings.settings.columnLayout {
            settings.settings.columnLayout = layout
        }
    }

    private func applySortIndicator() {
        let order = settings.settings.sortOrder
        let indicator = NSImage(named: order.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
        for column in outlineView.tableColumns {
            let isSortColumn = column.identifier.rawValue == order.column.rawValue
            outlineView.setIndicatorImage(isSortColumn ? indicator : nil, in: column)
        }
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let column = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw))
        else { return }
        column.isHidden.toggle()
        saveColumnLayout()
    }

    // MARK: - Icons

    private func scheduleIconPass() {
        guard !iconPassScheduled else { return }
        iconPassScheduled = true
        Task { @MainActor [weak self] in self?.loadVisibleIcons() }
    }

    /// Replaces type placeholders by the files' own icons for the visible rows, in small batches.
    private func loadVisibleIcons() {
        iconPassScheduled = false
        let columnIndex = outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name))
        guard columnIndex >= 0, let visible = Range(outlineView.rows(in: outlineView.visibleRect)) else { return }
        var loaded = 0
        for row in visible {
            guard
                let cell = outlineView.view(atColumn: columnIndex, row: row, makeIfNecessary: false)
                    as? FileNameCellView,
                !cell.hasFileIcon, let node = node(atRow: row)
            else { continue }
            cell.imageView?.image = icons.loadFileIcon(for: node.url)
            cell.hasFileIcon = true
            loaded += 1
            if loaded >= 32 {
                scheduleIconPass()
                return
            }
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension FileListController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return roots[index] }
        return node.children?[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.item.isDirectory ?? false
    }

    /// Rows can be dragged out (e.g. onto the sidebar Favorites or Finder) as file URLs.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        (item as? FileNode)?.url as NSURL?
    }
}

// MARK: - NSOutlineViewDelegate

extension FileListController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tableColumn, let node = item as? FileNode else { return nil }
        if tableColumn.identifier == .checkboxColumn {
            // Clicks are handled by `FileOutlineView.mouseDown`; the cell only mirrors the selection.
            let cell =
                outlineView.makeView(withIdentifier: .checkboxCell, owner: self) as? CheckboxCellView
                ?? CheckboxCellView()
            let row = outlineView.row(forItem: node)
            cell.checkbox.state = row >= 0 && outlineView.isRowSelected(row) ? .on : .off
            return cell
        }
        guard let column = FileColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let alpha: CGFloat = node.item.isHidden ? 0.5 : 1

        if column == .name {
            let cell =
                outlineView.makeView(withIdentifier: .nameCell, owner: self) as? FileNameCellView
                ?? FileNameCellView()
            cell.textField?.stringValue = node.item.name
            if let icon = icons.cachedFileIcon(for: node.url) {
                cell.imageView?.image = icon
                cell.hasFileIcon = true
            } else {
                cell.imageView?.image = icons.placeholder(for: node.item)
                cell.hasFileIcon = false
                scheduleIconPass()
            }
            cell.alphaValue = alpha
            return cell
        }

        let identifier: NSUserInterfaceItemIdentifier = column == .size ? .rightAlignedTextCell : .textCell
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? FileTextCellView
            ?? FileTextCellView(identifier: identifier, alignment: column == .size ? .right : .left)
        cell.textField?.stringValue = FileListFormat.text(for: column, of: node.item)
        cell.alphaValue = alpha
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        let columnIndex = outlineView.column(withIdentifier: .checkboxColumn)
        guard columnIndex >= 0, let cell = rowView.view(atColumn: columnIndex) as? CheckboxCellView else { return }
        cell.checkbox.state = outlineView.isRowSelected(row) ? .on : .off
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateCheckboxStates()
        outlineView.quickLook?.selectionDidChange()
        guard !isApplyingChanges else { return }
        writeSelectionToModel()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if node.children != nil { return true }
        if node.loadTask == nil { loadChildren(of: node, expand: true) }
        return false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        updateCheckboxStates()
        guard !isApplyingChanges, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedURLs.insert(node.url)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        updateCheckboxStates()
        guard !isApplyingChanges, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        expandedURLs.remove(node.url)
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier.rawValue == FileColumn.name.rawValue else { return nil }
        return (item as? FileNode)?.item.name
    }

    // Header

    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
        if tableColumn.identifier == .checkboxColumn {
            toggleSelectAll()
            return
        }
        guard let column = FileColumn(rawValue: tableColumn.identifier.rawValue) else { return }
        var order = settings.settings.sortOrder
        if order.column == column {
            order.ascending.toggle()
        } else {
            order.column = column
            order.ascending = true
        }
        settings.settings.sortOrder = order
    }

    /// The checkbox column stays first: it can't be moved, and nothing can move before it.
    func outlineView(_ outlineView: NSOutlineView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        columnIndex != 0 && newColumnIndex != 0
    }

    func outlineViewColumnDidMove(_ notification: Notification) {
        saveColumnLayout()
    }

    func outlineViewColumnDidResize(_ notification: Notification) {
        saveColumnLayout()
    }
}

// MARK: - Header menu

extension FileListController: NSMenuDelegate {
    /// Every column except Name (always visible), with a checkmark when shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in FileColumn.allCases where column != .name {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            let isHidden = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column))?.isHidden ?? true
            item.state = isHidden ? .off : .on
            menu.addItem(item)
        }
    }
}
