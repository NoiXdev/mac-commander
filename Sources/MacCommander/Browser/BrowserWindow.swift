import AppKit
import MacCommanderCore
import SwiftUI

// `@Entry` and `@State` are macros whose plugin is missing under Command Line Tools, so the
// focused-value keys are spelled out and `State` is used as a plain property.
private struct BrowserModelKey: FocusedValueKey { typealias Value = BrowserModel }
private struct GoToFolderPresentedKey: FocusedValueKey { typealias Value = Binding<Bool> }
private struct ShareSheetsKey: FocusedValueKey { typealias Value = ShareSheets }
private struct SearchFocusedKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    var browserModel: BrowserModel? {
        get { self[BrowserModelKey.self] }
        set { self[BrowserModelKey.self] = newValue }
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

/// One browser window: sidebar, toolbar and the panes of its `PaneLayout` (see `PaneView`). The sidebar,
/// toolbar, search field, title, preview, sheets and menus act on the active pane.
struct BrowserWindow: View {
    @Environment(ViewSettingsStore.self) private var settings
    @Environment(PreferencesStore.self) private var preferences
    @Environment(FileOperationCenter.self) private var operations
    @Environment(ShareManager.self) private var shareManager
    @SceneStorage("currentFolderPath") private var storedPath = ""
    private let layoutState = State<PaneLayout?>(initialValue: nil)
    /// One preview controller per pane, created when the pane first becomes active (Ruling P7-4).
    private let previewsState = State<[ObjectIdentifier: PreviewController]>(initialValue: [:])
    /// The pane the search `.task` last ran for; a pane switch doesn't restart that pane's shown search.
    private let searchPaneState = State<ObjectIdentifier?>(initialValue: nil)
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
    private var searchPane: ObjectIdentifier? {
        get { searchPaneState.wrappedValue }
        nonmutating set { searchPaneState.wrappedValue = newValue }
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
            let model = makeModel(start: Self.startURL(storedPath: storedPath))
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
            previews = [model.paneID: PreviewController(model: model, settings: settings)]
            layout = PaneLayout(primary: model, makePane: { makeModel(start: $0) })
        }
    }

    /// A pane's model: starts at `start`; new-file names and share lookups come from the app's stores.
    private func makeModel(start: URL) -> BrowserModel {
        let model = BrowserModel(start: start, settings: settings, operations: operations)
        model.newFileName = { [preferences] in preferences.preferences.effectiveNewFileName }
        // A pure lookup (no file-system access): a vanished folder on a saved share shows Disconnected.
        model.shareResolver = { [weak shareManager] url in
            guard let shareManager, let hit = shareManager.mountPoint(containing: url) else { return nil }
            let status = shareManager.status[hit.share.id]
            let isConnected = status == .connected(mountPoint: hit.mountPoint)
            // Server known to be gone: the window shows Disconnected without statting the dead path. Not for
            // an available share: its lookup may come from the old mount path, where another volume (a USB
            // disk with the same name) may be mounted now, which must stay browsable.
            let isKnownDisconnected = status == .unreachable
            return (hit.share.id, hit.share.name, hit.mountPoint, isConnected, isKnownDisconnected)
        }
        // A window showing Disconnected has the manager re-check that share (its status may be stale).
        model.shareDropped = { [shareManager] id in shareManager.recheck(id) }
        return model
    }

    private func content(_ layout: PaneLayout) -> some View {
        let model = layout.active
        return NavigationSplitView {
            SidebarView(model: model, shareSheets: shareSheets)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // The panes stay the split view's first children whether or not the preview is shown, and are
                // identified by their model, so each keeps its identity (controller, scroll position, selection)
                // when the preview toggles or another pane comes or goes.
                HSplitView {
                    ForEach(layout.panes, id: \.paneID) { pane in
                        PaneView(
                            model: pane, layout: layout, isActive: pane === layout.active,
                            showsActiveMarker: layout.isDual,
                            // The scene restores the first pane's folder.
                            onFolderChange: { url in
                                if pane === layout.panes.first { storedPath = url.path }
                            })
                            .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if settings.settings.showPreview, let preview = previews[model.paneID] {
                        PreviewPane(controller: preview)
                            .frame(minWidth: 240, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .environment(shareSheets)
                OperationsStrip()
            }
            .searchable(text: searchText(layout), placement: .toolbar, prompt: String(localized: "Search"))
            .searchFocused($searchFieldFocused)
            // Debounced: each keystroke restarts the wait. Clearing the field ends the search at once. Per pane:
            // switching to a pane whose search already shows the field's text doesn't restart it.
            .task(id: SearchRequest(pane: model.paneID, text: layout.searchText(for: model))) {
                let text = layout.searchText(for: model)
                let paneChanged = searchPane != model.paneID
                searchPane = model.paneID
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    // Not a tag view: the field is also cleared when one starts. With no search shown this still
                    // drops a search request that is checking its folder.
                    if case .tag? = model.search?.scope {} else { model.endSearch() }
                    return
                }
                if paneChanged, model.search == SearchQuery(text: trimmed, scope: .folder(model.currentURL)) {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.startSearch(text)
            }
        }
        // On the split view, which exists exactly while the layout does (not on the Group's branches, whose
        // switch from `Color.clear` would fire them around creation). Only the active pane's preview runs;
        // closing the window stops extraction and rendering for every pane's preview. Both calls are idempotent.
        .onAppear { syncPreviews(layout) }
        .onChange(of: model.paneID) { syncPreviews(layout) }
        .onDisappear { previews.values.forEach { $0.stop() } }
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
                Button {
                    settings.settings.showPreview.toggle()
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
        .background(WindowReader(box: shareSheets.window))
    }

    /// The toolbar search field shows the active pane's text; a search starts 250 ms after the last change.
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
        let activeController = previews[active.paneID] ?? PreviewController(model: active, settings: settings)
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

/// The search `.task`'s id: the active pane and its field text.
private struct SearchRequest: Equatable {
    let pane: ObjectIdentifier
    let text: String
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
