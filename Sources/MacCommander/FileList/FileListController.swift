import AppKit
import MacCommanderCore
import Observation
import SwiftUI

/// persistent columns (`settings.columnLayout`) and a checkbox column mirroring the selection.
final class FileListController: NSViewController {
    let model: BrowserModel
    let settings: ViewSettingsStore

    private(set) var outlineView = FileOutlineView()
    let scrollView = NSScrollView()
    var errorHost: NSHostingView<LoadErrorView>?
    /// Shown when a load takes longer than `spinnerDelay`.
    let spinner = NSProgressIndicator()
    var spinnerTask: Task<Void, Never>?
    static let spinnerDelay: Duration = .milliseconds(300)
    /// Shown for a listed folder without items.
    private let emptyLabel = PassthroughLabel(labelWithString: String(localized: "No items"))

    var roots: [FileNode] = []
    /// Folders the user expanded, restored by URL after reloads.
    var expandedURLs: Set<URL> = []
    var displayedFolder: URL?
    /// The selection last exchanged with the model; avoids redundant row scans.
    var syncedSelection: Set<URL> = []
    /// > 0 while the controller changes rows or selection itself, so callbacks don't write back.
    var changeDepth = 0
    var isApplyingChanges: Bool { changeDepth > 0 }
    /// True while columns are adjusted to the settings, so resize/move callbacks don't write back.
    var isApplyingLayout = false
    let icons = FileIconProvider()
    var iconPassScheduled = false
    /// Inline rename state (see `FileListController+Rename.swift`).
    var rename = InlineRenameState()

    /// Above this many inserted/removed/changed rows, a reload is cheaper than row animations.
    static let maxIncrementalChanges = 500

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(outlineView)
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
            column.isHidden = state.column != .name && !state.isVisible
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

    func applyLoadError() {
        updateEmptyLabel()
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

    // MARK: - Loading and empty state

    /// The spinner appears only when loading takes noticeably long, so quick loads don't flicker.
    func applyLoadingState() {
        spinnerTask?.cancel()
        spinnerTask = nil
        if model.isLoading {
            if spinner.isHidden {
                spinnerTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.spinnerDelay)
                    guard !Task.isCancelled, let self, self.model.isLoading else { return }
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

    /// "No items" only for a successfully listed, empty current folder (not while loading).
    func updateEmptyLabel() {
        let isEmptyFolder =
            !model.isLoading && model.loadError == nil && model.items.isEmpty
            && model.listedURL != nil && model.listedURL == model.currentURL
        if emptyLabel.isHidden == isEmptyFolder { emptyLabel.isHidden = !isEmptyFolder }
    }
}

/// A label that lets clicks through to the list below (e.g. a right-click for New Folder).
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
