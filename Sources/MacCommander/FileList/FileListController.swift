import AppKit
import MacCommanderCore
import Observation
import SwiftUI

/// The file list: a view-based NSOutlineView showing model.items, with inline folder expansion,
/// persistent columns (`settings.columnLayout`) and a checkbox column mirroring the selection.
final class FileListController: NSViewController {
    let model: BrowserModel
    let settings: ViewSettingsStore
    /// The app's file clipboard (copy/cut/paste).
    let clipboard: FileClipboard
    /// Opens the info window for a URL (SwiftUI's `openWindow`, supplied by `FileListView`).
    var openInfo: (URL) -> Void
    /// The terminal chosen in Settings, for "Open in Terminal" (supplied by `FileListView`).
    var terminalApp: () -> TerminalApp? = { nil }
    /// "Reconnect" for a dropped network share (supplied by `FileListView`); nil hides the button.
    var reconnect: ((DisconnectedShare) -> Void)? {
        didSet { if isViewLoaded, case .shareDisconnected? = model.loadError { applyLoadError() } }
    }
    /// "Sign In…" for a dropped network share (supplied by `FileListView`); nil hides the button.
    var signIn: ((DisconnectedShare) -> Void)? {
        didSet { if isViewLoaded, case .shareDisconnected? = model.loadError { applyLoadError() } }
    }

    /// The list took keyboard focus (or its placeholder was clicked): its pane becomes active (supplied by
    /// `FileListView`).
    var onActivate: (() -> Void)? {
        didSet { outlineView.onBecomeFirstResponder = onActivate }
    }
    /// Tab / ⇧Tab in the list: switch panes (dual-pane mode only; supplied by `FileListView`).
    var onSwitchPane: (() -> Void)? {
        didSet { outlineView.onSwitchPane = onSwitchPane }
    }
    /// F5/F6 and Copy/Move to Other Pane (supplied by `FileListView`); nil outside dual-pane mode.
    var paneCommands: PaneCommands?
    /// False for a pane that isn't the active one: it doesn't take keyboard focus when it appears.
    var takesFocusOnAppear = true
    /// The pane layout's focus request (`PaneLayout.focusSerial`) last handled.
    var appliedFocusSerial = 0

    private(set) var outlineView = FileOutlineView()
    let scrollView = NSScrollView()
    var errorHost: NSHostingView<LoadErrorView>?
    /// Shown when a load takes longer than `spinnerDelay`.
    let spinner = NSProgressIndicator()
    var spinnerTask: Task<Void, Never>?
    static let spinnerDelay: Duration = .milliseconds(300)
    /// Shown for a listed folder without items.
    private let emptyLabel = PassthroughLabel(labelWithString: L10n.string("fileList.empty.noItems", "No items"))

    var roots: [FileNode] = []
    /// Folders the user expanded, restored by URL after reloads.
    var expandedURLs: Set<URL> = []
    var displayedFolder: URL?
    /// The search whose results the rows show (nil: the folder's listing). A new search resets the tree; a
    /// re-run of the same one is diffed like a reload.
    var displayedSearch: SearchQuery?
    /// The selection last exchanged with the model; avoids redundant row scans.
    var syncedSelection: Set<URL> = []
    /// > 0 while the controller changes rows or selection itself, so callbacks don't write back.
    var changeDepth = 0
    var isApplyingChanges: Bool { changeDepth > 0 }
    /// True while columns are adjusted to the settings, so resize/move callbacks don't write back.
    var isApplyingLayout = false
    let icons = FileIconProvider()
    /// The row size the rows and icons are laid out for (see `applyRowSize()`).
    var rowSize = RowSize.regular
    var iconPassScheduled = false
    /// The folder whose batch of file icons is loading off the main actor; one batch per folder at a time. A
    /// batch that hangs (unresponsive server) doesn't hold up the icons of the next folder shown.
    var iconBatchFolder: URL?
    /// Inline rename state (see `FileListController+Rename.swift`).
    var rename = InlineRenameState() {
        didSet {
            if (oldValue.session == nil) != (rename.session == nil) { onRenamingChanged?(rename.session != nil) }
        }
    }
    /// An inline rename started or ended (supplied by `FileListView`).
    var onRenamingChanged: ((Bool) -> Void)?
    /// Extracts archive entries for Quick Look, for `selection` (row URLs). Space with the same selection or a
    /// selection change cancels it (see `toggleQuickLook`).
    var quickLookTask: (task: Task<Void, Never>, selection: [URL])?

    /// The payload of the archive drag being set up, for the selected rows it was computed for.
    var archiveDragPayload: (selection: IndexSet, payload: ArchiveDragPayload)?

    /// The source operations of rows outside archives.
    static let fileDragOperations: NSDragOperation = [.copy, .move, .generic]

    /// Above this many inserted/removed/changed rows, a reload is cheaper than row animations.
    static let maxIncrementalChanges = 500

    init(model: BrowserModel, settings: ViewSettingsStore, clipboard: FileClipboard, openInfo: @escaping (URL) -> Void) {
        self.model = model
        self.openInfo = openInfo
        self.settings = settings
        self.clipboard = clipboard
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
        configureStatusViews(in: container)
        view = container

        applySettings()
        applyItems()
        applyLoadError()
        applyLoadingState()
        observeItems()
        observeLoading()
        observeCurrentFolder()
        observeSelection()
        observeLoadError()
        observeSettings()
        observePendingRename()
        observeOperationFolders()
        observeSearch()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if takesFocusOnAppear { view.window?.makeFirstResponder(outlineView) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scrollSelectionIntoViewIfRequested()
    }

    /// Takes keyboard focus once per new focus request (`serial`) that names this list. After the SwiftUI
    /// update that delivered it, since becoming first responder activates the pane.
    func applyFocusRequest(serial: Int, isTarget: Bool) {
        guard serial != appliedFocusSerial else { return }
        appliedFocusSerial = serial
        guard isTarget else { return }
        Task { @MainActor [weak self] in self?.takeFocus() }
    }

    /// Makes the list first responder, which activates its pane. If it can't take focus (e.g. a placeholder
    /// hides it), the window keeps no list focused, so responder-chain commands can't reach the other pane's
    /// list while this pane is active.
    func takeFocus() {
        guard let window = view.window, window.firstResponder !== outlineView else {
            onActivate?()
            return
        }
        if !window.makeFirstResponder(outlineView) {
            window.makeFirstResponder(nil)
            onActivate?()
        }
    }

    func configureOutline() {
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
        // Rows drag out as file URLs (to Finder, the Desktop, other apps, the sidebar or this list);
        // the destination picks copy or move. Dragging into the Trash (`.delete`) is not offered.
        // Archive entries drag as copies only (see `outlineView(_:draggingSession:willBeginAt:forItems:)`) and
        // arrive as `archiveEntries`.
        outline.setDraggingSourceOperationMask(Self.fileDragOperations, forLocal: false)
        outline.setDraggingSourceOperationMask(Self.fileDragOperations, forLocal: true)
        outline.registerForDraggedTypes([.archiveEntries, .fileURL])

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
        outline.onTransfer = { [weak self] move in
            guard let commands = self?.paneCommands, commands.requestTransfer(move) else { return NSSound.beep() }
        }
        // Beeps inside an archive and during a search, like the menu item's shortcut.
        outline.onNewFolder = { [weak self] in
            guard let model = self?.model else { return }
            Task { await BrowserActions.newFolder(model) }
        }
        outline.contextMenu = { [weak self] row in self?.contextMenu(forRow: row) }
        outline.allowsInteraction = { [weak self] in self?.showsCurrentFolder ?? false }
        outline.commandHandler = self
        // Inside an archive the rows' URLs are virtual: the panel shows extracted copies instead.
        outline.quickLook = QuickLookController(
            keyTarget: outline, previewsSelection: { [weak self] in self?.model.archiveLocation == nil }
        ) { [weak self] in
            self?.selectedNodes.map(\.url) ?? []
        }
        outline.dataSource = self
        outline.delegate = self
    }

    /// The spinner and the "No items" label, centered above the list.
    func configureStatusViews(in container: NSView) {
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        emptyLabel.isHidden = true
        for status in [spinner, emptyLabel] as [NSView] {
            status.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(status)
            NSLayoutConstraint.activate([
                status.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                status.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        }
    }

    func makeColumns() {
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
            column.isHidden = isColumnHidden(state)
            if state.column == .size { column.headerCell.alignment = .right }
            outlineView.addTableColumn(column)
            if state.column == .name { outlineView.outlineTableColumn = column }
        }
    }

    var checkboxColumn: NSTableColumn? {
        outlineView.tableColumn(withIdentifier: .checkboxColumn)
    }

    // MARK: - Observation

    func observeItems() {
        withObservationTracking {
            _ = model.items
            _ = model.listedURL
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeItems()
                self?.applyItems()
            }
        }
    }

    /// Navigation changes `currentURL` before the new items arrive: clear the old rows at once,
    /// so nothing from the previous folder can be selected or opened meanwhile. (`applyItems`
    /// shows only a listing of the current folder; going back to the listed folder restores it.)
    func observeCurrentFolder() {
        withObservationTracking {
            _ = model.currentURL
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeCurrentFolder()
                self?.currentFolderDidChange()
            }
        }
    }

    func currentFolderDidChange() {
        guard model.currentURL != displayedFolder else { return }
        if displayedFolder != nil || !roots.isEmpty {
            endRename(commit: true)
            cancelArchiveQuickLook()
            outlineView.quickLook?.folderDidChange()
        }
        applyItems()
    }

    /// False while the rows still belong to a folder other than `model.currentURL`.
    var showsCurrentFolder: Bool {
        displayedFolder == model.currentURL
    }

    func observeSelection() {
        withObservationTracking {
            _ = model.selection
        } onChange: { [weak self] in
            Task { @MainActor in self?.selectionDidChangeInModel() }
        }
    }

    func selectionDidChangeInModel() {
        observeSelection()
        if model.selection != syncedSelection { syncSelectionFromModel() }
    }

    func observeLoading() {
        withObservationTracking {
            _ = model.isLoading
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeLoading()
                self?.applyLoadingState()
            }
        }
    }

    func observeLoadError() {
        withObservationTracking {
            _ = model.loadError
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeLoadError()
                self?.applyLoadError()
            }
        }
    }

    /// A search starting or ending changes the Location column, the status text and the error view.
    func observeSearch() {
        withObservationTracking {
            _ = model.search
            _ = model.searchIsRunning
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeSearch()
                self.applyColumnLayout()
                self.applySortIndicator()
                self.applyLoadError()
                self.applyLoadingState()
            }
        }
    }

    func observeSettings() {
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

    /// Not while a search is shown: its results don't depend on the folder's own listing.
    func applyLoadError() {
        updateEmptyLabel()
        guard let error = model.loadError, !model.isSearching else {
            errorHost?.isHidden = true
            scrollView.isHidden = false
            return
        }
        var reconnectAction: (() -> Void)?
        var signInAction: (() -> Void)?
        if let share = model.disconnectedShare {
            if let reconnect { reconnectAction = { reconnect(share) } }
            if let signIn { signInAction = { signIn(share) } }
        }
        let errorView = LoadErrorView(
            error: error, enterPassword: { [weak self] in self?.askForArchivePassword() }, reconnect: reconnectAction,
            signIn: signInAction,
            // Dual-pane mode only (the list then has a pane to switch to): activates this pane.
            onClick: { [weak self] in
                guard let self, self.onSwitchPane != nil else { return }
                self.takeFocus()
            })
        if let errorHost {
            errorHost.rootView = errorView
            errorHost.isHidden = false
        } else {
            let host = NSHostingView(rootView: errorView)
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host, positioned: .below, relativeTo: spinner)
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

    /// "Enter Password…" in the load error view: asks for the shown archive's password and lists it
    /// again with it. A cancelled sheet leaves the error showing.
    func askForArchivePassword() {
        let archive: URL
        switch model.loadError {
        case .archivePasswordRequired(let url)?, .archiveIncorrectPassword(let url)?: archive = url
        default: return
        }
        let model = model
        let window = view.window
        Task {
            guard let password = await ArchivePasswordSheet.ask(for: archive, window: window) else { return }
            await model.providePassword(password)
        }
    }

    // MARK: - Loading and empty state

    /// The spinner appears only when loading takes noticeably long, so quick loads don't flicker. A shown
    /// search has its own status text instead (see `updateEmptyLabel`).
    func applyLoadingState() {
        spinnerTask?.cancel()
        spinnerTask = nil
        if model.isLoading, !model.isSearching {
            if spinner.isHidden {
                spinnerTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.spinnerDelay)
                    guard !Task.isCancelled, let self, self.model.isLoading, !self.model.isSearching else { return }
                    self.spinner.isHidden = false
                    self.spinner.startAnimation(nil)
                }
            }
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
        updateEmptyLabel()
    }

    /// "No items" only for a successfully listed, empty current folder (not while loading). While a search
    /// without results is shown: "Searching…" until it finishes, then "No Results".
    func updateEmptyLabel() {
        let text: String?
        if model.isSearching {
            text = !model.items.isEmpty
                ? nil
                : model.searchIsRunning ? L10n.string("fileList.empty.searching", "Searching…") : L10n.string("fileList.empty.noResults", "No Results")
        } else {
            let isEmptyFolder =
                !model.isLoading && model.loadError == nil && model.items.isEmpty
                && model.listedURL != nil && model.listedURL == model.currentURL
            text = isEmptyFolder ? L10n.string("fileList.empty.noItems", "No items") : nil
        }
        if let text, emptyLabel.stringValue != text { emptyLabel.stringValue = text }
        if emptyLabel.isHidden != (text == nil) { emptyLabel.isHidden = text == nil }
    }
}

/// A label that lets clicks through to the list below (e.g. a right-click for New Folder).
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
