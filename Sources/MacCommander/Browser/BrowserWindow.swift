import AppKit
import MacCommanderCore
import SwiftUI

// `@Entry` and `@State` are macros whose plugin is missing under Command Line Tools, so the
// focused-value keys are spelled out and `State` is used as a plain property.
private struct BrowserModelKey: FocusedValueKey { typealias Value = BrowserModel }
private struct PaneLayoutKey: FocusedValueKey { typealias Value = PaneLayout }
private struct GoToFolderPresentedKey: FocusedValueKey { typealias Value = Binding<Bool> }
private struct ShareSheetsKey: FocusedValueKey { typealias Value = ShareSheets }
private struct SearchFocusedKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    /// The focused window's active pane.
    var browserModel: BrowserModel? {
        get { self[BrowserModelKey.self] }
        set { self[BrowserModelKey.self] = newValue }
    }
    /// The focused window's panes (mode switching, the preview setting of its mode).
    var paneLayout: PaneLayout? {
        get { self[PaneLayoutKey.self] }
        set { self[PaneLayoutKey.self] = newValue }
    }
    var goToFolderPresented: Binding<Bool>? {
        get { self[GoToFolderPresentedKey.self] }
        set { self[GoToFolderPresentedKey.self] = newValue }
    }
    /// The focused window's share sheets (Go ▸ Connect to Server…).
    var shareSheets: ShareSheets? {
        get { self[ShareSheetsKey.self] }
        set { self[ShareSheetsKey.self] = newValue }
    }
    /// Focuses the focused window's search field (Edit ▸ Find…).
    var searchFocused: Binding<Bool>? {
        get { self[SearchFocusedKey.self] }
        set { self[SearchFocusedKey.self] = newValue }
    }
}

extension PaneLayout {
    /// View ▸ Single Pane / Dual Pane and the toolbar button.
    func toggleMode() {
        if isDual { showSingle() } else { showDual() }
    }
}

/// One browser window: sidebar, toolbar and the panes of its `PaneLayout` (see `PaneView`). The sidebar,
/// toolbar, search field, title, preview, sheets and menus act on the active pane.
struct BrowserWindow: View {
    @Environment(ViewSettingsStore.self) private var settings
    @Environment(PreferencesStore.self) private var preferences
    @Environment(FileOperationCenter.self) private var operations
    @Environment(ShareManager.self) private var shareManager
    // Restored per window: both panes' folders (the second one's also while it is closed), the mode and the
    // active pane. `currentFolderPath` is v1's key, for the first pane.
    @SceneStorage("currentFolderPath") private var storedPath = ""
    @SceneStorage("secondFolderPath") private var storedSecondPath = ""
    @SceneStorage("isDualPane") private var storedIsDual = false
    @SceneStorage("activePane") private var storedActivePane = 0
    private let layoutState = State<PaneLayout?>(initialValue: nil)
    /// One preview controller per pane, created when the pane first becomes active (Ruling P7-4).
    private let previewsState = State<[ObjectIdentifier: PreviewController]>(initialValue: [:])
    private let goToFolderState = State(initialValue: false)
    private let shareSheetsState = State(initialValue: ShareSheets())
    /// The Finder name of a folder, resolved off the main actor; the title shows it once it matches.
    private let titleState = State<(url: URL, name: String)?>(initialValue: nil)
    /// `FocusState` is a property wrapper (no macro plugin needed).
    @FocusState private var searchFieldFocused: Bool
    private var layout: PaneLayout? {
        get { layoutState.wrappedValue }
        nonmutating set { layoutState.wrappedValue = newValue }
    }
    private var previews: [ObjectIdentifier: PreviewController] {
        get { previewsState.wrappedValue }
        nonmutating set { previewsState.wrappedValue = newValue }
    }
    private var showGoToFolder: Binding<Bool> { goToFolderState.projectedValue }
    private var shareSheets: ShareSheets { shareSheetsState.wrappedValue }
    private var resolvedTitle: (url: URL, name: String)? {
        get { titleState.wrappedValue }
        nonmutating set { titleState.wrappedValue = newValue }
    }

    var body: some View {
        Group {
            if let layout {
                content(layout)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard layout == nil else { return }
            // Every pane, also one opened later by `showDual()`, is made by this one factory with the app's stores.
            let makePane = Self.paneFactory(
                settings: settings, preferences: preferences, operations: operations, shareManager: shareManager)
            let model = makePane(Self.startURL(storedPath: storedPath))
            if !storedPath.hasPrefix("/") {
                // New window: starts at home at once; the preferred folder is checked off main, then replaces
                // the start (no Back entry to home), unless the user navigated meanwhile.
                let prefs = preferences.preferences
                let home = model.currentURL
                Task {
                    let folder = await PathQueries.run {
                        prefs.newWindowFolder(exists: { url in
                            var isDirectory: ObjCBool = false
                            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                                && isDirectory.boolValue
                        })
                    }
                    if folder.standardizedFileURL.path != home.standardizedFileURL.path {
                        await model.replaceStart(with: folder)
                    }
                }
            }
            // A gone second folder falls back like the first (the model's first load, off the main actor).
            let second = storedSecondPath.hasPrefix("/") ? URL(fileURLWithPath: storedSecondPath, isDirectory: true) : nil
            let layout = PaneLayout(primary: model, rememberedSecondFolder: second, makePane: makePane)
            // New windows start single (their scene storage is empty); with the setting off, restored ones too.
            if storedIsDual, preferences.preferences.dualPaneEnabled {
                layout.showDual()
                layout.activate(layout.panes[min(max(storedActivePane, 0), layout.panes.count - 1)])
            }
            previews = [layout.active.paneID: makePreview(layout.active, layout: layout)]
            self.layout = layout
        }
    }

    /// Makes a pane's model: starts at the given folder; new-file names and share lookups come from the app's
    /// stores, which are captured here (not read from the window's environment later).
    private static func paneFactory(
        settings: ViewSettingsStore, preferences: PreferencesStore, operations: FileOperationCenter,
        shareManager: ShareManager
    ) -> @MainActor (URL) -> BrowserModel {
        { [settings, preferences, operations, shareManager] start in
            let model = BrowserModel(start: start, settings: settings, operations: operations)
            model.newFileName = { [preferences] in preferences.preferences.effectiveNewFileName }
            // A pure lookup (no file-system access): a vanished folder on a saved share shows Disconnected.
            model.shareResolver = { [weak shareManager] url in
                guard let shareManager, let hit = shareManager.mountPoint(containing: url) else { return nil }
                let status = shareManager.status[hit.share.id]
                let isConnected = status == .connected(mountPoint: hit.mountPoint)
                // Server known to be gone: the pane shows Disconnected without statting the dead path. Not for
                // an available share: its lookup may come from the old mount path, where another volume (a USB
                // disk with the same name) may be mounted now, which must stay browsable.
                let isKnownDisconnected = status == .unreachable
                return (hit.share.id, hit.share.name, hit.mountPoint, isConnected, isKnownDisconnected)
            }
            // A pane showing Disconnected has the manager re-check that share (its status may be stale).
            model.shareDropped = { [shareManager] id in shareManager.recheck(id) }
            return model
        }
    }

    /// A pane's preview controller; it shows content while the setting of the window's current mode is on.
    private func makePreview(_ pane: BrowserModel, layout: PaneLayout) -> PreviewController {
        PreviewController(model: pane, settings: settings, isShown: { [settings, weak layout] in
            settings.settings.showsPreview(dualPane: layout?.isDual ?? false)
        })
    }

    private func content(_ layout: PaneLayout) -> some View {
        let model = layout.active
        let isDual = layout.isDual
        return NavigationSplitView {
            SidebarView(model: model, shareSheets: shareSheets)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // The panes stay the split view's first children whether or not the preview is shown, and are
                // identified by their model, so each keeps its identity (controller, scroll position, selection)
                // when the preview toggles, the mode changes or another pane becomes active.
                HSplitView {
                    ForEach(layout.panes, id: \.paneID) { pane in
                        PaneView(
                            model: pane, layout: layout, isActive: pane === model, showsActiveMarker: isDual,
                            showsFooter: isDual)
                            .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if settings.settings.showsPreview(dualPane: isDual), let preview = previews[model.paneID] {
                        PreviewPane(controller: preview)
                            .frame(minWidth: 240, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .environment(shareSheets)
                // Single-pane mode: across the full width, below the preview too (as in v1).
                if !isDual {
                    PaneFooter(model: model)
                }
                OperationsStrip()
            }
            .searchable(text: searchText(layout), placement: .toolbar, prompt: String(localized: "Search"))
            .searchFocused($searchFieldFocused)
        }
        // On the split view, which exists exactly while the layout does (not on the Group's branches, whose
        // switch from `Color.clear` would fire them around creation). Only the active pane's preview runs;
        // closing the window stops extraction and rendering for every pane's preview. Both calls are idempotent.
        .onAppear { syncPreviews(layout) }
        .onChange(of: model.paneID) { syncPreviews(layout) }
        .onChange(of: layout.panes.map(\.paneID)) { syncPreviews(layout) }
        .onDisappear { previews.values.forEach { $0.stop() } }
        .onChange(of: StoredPanes(layout), initial: true) { _, stored in
            storedPath = stored.first
            storedSecondPath = stored.second
            storedIsDual = stored.isDual
            storedActivePane = stored.active
        }
        // Turning the setting off makes every window single-pane, keeping its active pane.
        .onChange(of: preferences.preferences.dualPaneEnabled) { _, enabled in
            if !enabled { layout.showSingle() }
        }
        // The last path component at once (no disk access), the localized name once it's resolved. A tag view
        // shows the tag's name.
        .navigationTitle(title(for: model))
        .task(id: model.currentURL) {
            let url = model.currentURL
            let name = await PathQueries.displayName(url)
            if url == model.currentURL { resolvedTitle = (url, name) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task { await model.goBack() }
                } label: {
                    Label(String(localized: "Back"), systemImage: "chevron.left")
                }
                // Back also closes a shown search (Ruling P6-1), even without history.
                .disabled(!model.history.canGoBack && !model.isSearching)
                Button {
                    Task { await model.goForward() }
                } label: {
                    Label(String(localized: "Forward"), systemImage: "chevron.right")
                }
                .disabled(!model.history.canGoForward)
            }
            ToolbarItemGroup {
                Button {
                    Task { await BrowserActions.newFolder(model) }
                } label: {
                    Label(String(localized: "New Folder"), systemImage: "folder.badge.plus")
                }
                // Archives are read-only; a shown search hides the folder the new one would land in.
                .disabled(model.archiveLocation != nil || model.isSearching)
                if preferences.preferences.dualPaneEnabled {
                    Button {
                        layout.toggleMode()
                    } label: {
                        Label(String(localized: "Dual Pane"), systemImage: "rectangle.split.2x1")
                    }
                    .help(String(localized: "Dual Pane"))
                }
                Button {
                    settings.settings.togglePreview(dualPane: isDual)
                } label: {
                    Label(String(localized: "Preview"), systemImage: "sidebar.right")
                }
                .help(String(localized: "Preview"))
                Button {
                    settings.settings.showHiddenFiles.toggle()
                } label: {
                    Label(
                        String(localized: "Toggle Hidden Files"),
                        systemImage: settings.settings.showHiddenFiles ? "eye" : "eye.slash")
                }
            }
        }
        .focusedSceneValue(\.browserModel, model)
        .focusedSceneValue(\.paneLayout, layout)
        .focusedSceneValue(\.goToFolderPresented, showGoToFolder)
        .focusedSceneValue(\.searchFocused, Binding(
            get: { searchFieldFocused }, set: { searchFieldFocused = $0 }))
        .sheet(isPresented: showGoToFolder) { GoToFolderSheet(model: model) }
        // Mirrored for ⌘K and the queued sign-in sheet, which wait for every sheet of the window.
        .onChange(of: showGoToFolder.wrappedValue) { _, shown in shareSheets.showGoToFolder = shown }
        .focusedSceneValue(\.shareSheets, shareSheets)
        .sheet(isPresented: Bindable(shareSheets).showConnectToServer) {
            ConnectToServerSheet(model: model, sheets: shareSheets)
        }
        .sheet(item: Bindable(shareSheets).signIn) { share in
            SignInSheet(share: share, model: model, sheets: shareSheets)
        }
        .sheet(item: Bindable(shareSheets).editing) { share in
            EditShareSheet(share: share)
        }
        // F5/F6, ⌘5/⌘6 and Copy/Move to Other Pane. The other pane's folder doesn't change for an edited path.
        .sheet(item: Bindable(layout).pendingTransfer) { request in
            PaneTransferSheet(
                request: request,
                onConfirm: { [layout, shareSheets] destination in
                    layout.pendingTransfer = nil
                    Self.runTransfer(request, into: destination, layout: layout, window: shareSheets.window.window)
                },
                onCancel: { [layout] in layout.pendingTransfer = nil })
        }
        .background(WindowReader(box: shareSheets.window))
    }

    /// Runs a confirmed pane transfer; the results are selected in the target pane when it shows `destination`.
    private static func runTransfer(
        _ request: PaneTransferRequest, into destination: URL, layout: PaneLayout, window: NSWindow?
    ) {
        let target = layout.inactive ?? layout.active
        Task {
            switch request.kind {
            case .copy:
                await FileActions.transfer(request.sources, into: destination, mode: .copy, model: target, window: window)
            case .move:
                await FileActions.transfer(request.sources, into: destination, mode: .move, model: target, window: window)
            case .extract(let archive):
                await FileActions.extract(request.entries, from: archive, into: destination, model: target, window: window)
            }
        }
    }

    /// The toolbar search field shows the active pane's text; that pane's search starts 250 ms after the last
    /// change (see `PaneView`).
    private func searchText(_ layout: PaneLayout) -> Binding<String> {
        Binding(
            get: { layout.searchText(for: layout.active) },
            set: { layout.setSearchText($0, for: layout.active) })
    }

    /// Creates the active pane's preview controller if needed, resumes it and stops every other pane's;
    /// drops the controllers of panes that are gone.
    private func syncPreviews(_ layout: PaneLayout) {
        let active = layout.active
        var previews = previews
        let paneIDs = Set(layout.panes.map(\.paneID))
        for (id, controller) in previews where !paneIDs.contains(id) {
            controller.stop()
            previews[id] = nil
        }
        let activeController = previews[active.paneID] ?? makePreview(active, layout: layout)
        previews[active.paneID] = activeController
        for (id, controller) in previews where id != active.paneID { controller.stop() }
        activeController.resume()
        if Set(previews.keys) != Set(self.previews.keys) { self.previews = previews }
    }

    /// The restored folder (also a folder inside an archive), or home when nothing is stored. Not checked
    /// here, since it may be on a network volume: the model's first load falls back to the nearest existing
    /// ancestor, off the main actor, when it is gone.
    private static func startURL(storedPath: String) -> URL {
        guard storedPath.hasPrefix("/") else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: storedPath, isDirectory: true)
    }

    private func title(for model: BrowserModel) -> String {
        if case .tag(let name)? = model.search?.scope { return name }
        let url = model.currentURL
        if let resolvedTitle, resolvedTitle.url == url { return resolvedTitle.name }
        return url.path == "/" ? "/" : url.lastPathComponent
    }
}

/// What the window's scene storage keeps of its layout.
private struct StoredPanes: Equatable {
    /// panes[0]'s folder.
    let first: String
    /// panes[1]'s folder, or the one the second pane reopens at while it is closed ("" if none).
    let second: String
    let isDual: Bool
    let active: Int

    @MainActor init(_ layout: PaneLayout) {
        first = layout.panes[0].currentURL.path
        second = (layout.isDual ? layout.panes[1].currentURL : layout.rememberedSecondFolder)?.path ?? ""
        isDual = layout.isDual
        active = layout.activeIndex
    }
}

enum BrowserActions {
    @MainActor
    static func newFolder(_ model: BrowserModel, in directory: URL? = nil) async {
        // Archives are read-only (the menus are disabled there; this covers a shortcut that slips through).
        // During a search the current folder is hidden: only an explicit folder (a result's) takes new items.
        guard model.archiveLocation == nil, directory != nil || !model.isSearching else { return NSSound.beep() }
        do { _ = try await model.createFolder(in: directory) } catch { show(error) }
    }

    @MainActor
    static func newFile(_ model: BrowserModel, in directory: URL? = nil) async {
        guard model.archiveLocation == nil, directory != nil || !model.isSearching else { return NSSound.beep() }
        do { _ = try await model.createEmptyFile(in: directory) } catch { show(error) }
    }

    @MainActor
    private static func show(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}
