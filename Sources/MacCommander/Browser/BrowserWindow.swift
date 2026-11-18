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

/// One browser window: sidebar, file list, path bar and toolbar.
struct BrowserWindow: View {
    @Environment(ViewSettingsStore.self) private var settings
    @Environment(PreferencesStore.self) private var preferences
    @Environment(FileOperationCenter.self) private var operations
    @Environment(FileClipboard.self) private var clipboard
    @Environment(ShareManager.self) private var shareManager
    @Environment(ShareStore.self) private var shareStore
    @SceneStorage("currentFolderPath") private var storedPath = ""
    /// True while the window is key (or the app's active window); see the refresh on focus below.
    @Environment(\.appearsActive) private var appearsActive
    private let modelState = State<BrowserModel?>(initialValue: nil)
    private let previewState = State<PreviewController?>(initialValue: nil)
    private let goToFolderState = State(initialValue: false)
    private let shareSheetsState = State(initialValue: ShareSheets())
    /// The Finder name of a folder, resolved off the main actor; the title shows it once it matches.
    private let titleState = State<(url: URL, name: String)?>(initialValue: nil)
    /// The toolbar search field's text; a search starts 250 ms after the last change.
    private let searchTextState = State(initialValue: "")
    /// `FocusState` is a property wrapper (no macro plugin needed).
    @FocusState private var searchFieldFocused: Bool
    private var model: BrowserModel? {
        get { modelState.wrappedValue }
        nonmutating set { modelState.wrappedValue = newValue }
    }
    private var preview: PreviewController? {
        get { previewState.wrappedValue }
        nonmutating set { previewState.wrappedValue = newValue }
    }
    private var showGoToFolder: Binding<Bool> { goToFolderState.projectedValue }
    private var shareSheets: ShareSheets { shareSheetsState.wrappedValue }
    private var searchText: Binding<String> { searchTextState.projectedValue }
    private var resolvedTitle: (url: URL, name: String)? {
        get { titleState.wrappedValue }
        nonmutating set { titleState.wrappedValue = newValue }
    }

    var body: some View {
        Group {
            if let model, let preview {
                content(model, preview: preview)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard model == nil else { return }
            let model = BrowserModel(start: Self.startURL(storedPath: storedPath), settings: settings, operations: operations)
            model.newFileName = { [preferences] in preferences.preferences.effectiveNewFileName }
            if !storedPath.hasPrefix("/") {
                // New window: starts at home at once; the preferred folder's existence is checked off main.
                let prefs = preferences.preferences
                let home = model.currentURL
                Task {
                    let folder = await PathQueries.run {
                        prefs.newWindowFolder(exists: { FileManager.default.fileExists(atPath: $0.path) })
                    }
                    // Only if the user hasn't navigated meanwhile.
                    if folder != home, model.currentURL == home { _ = await model.navigate(to: folder) }
                }
            }
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
            self.model = model
            preview = PreviewController(model: model, settings: settings)
        }
    }

    private func content(_ model: BrowserModel, preview: PreviewController) -> some View {
        NavigationSplitView {
            SidebarView(model: model, shareSheets: shareSheets)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // The list stays the split view's first child whether or not the pane is shown, so it keeps
                // its identity (controller, scroll position, selection) when the pane toggles.
                HSplitView {
                    FileListView(
                        model: model, settings: settings, clipboard: clipboard,
                        reconnect: { [shareStore, shareManager, shareSheets] disconnected in
                            Task {
                                await ShareActions.reconnect(
                                    disconnected, store: shareStore, manager: shareManager, model: model,
                                    sheets: shareSheets)
                            }
                        },
                        signIn: { [shareStore, shareSheets] disconnected in
                            guard let share = shareStore.shares.first(where: { $0.id == disconnected.id }) else { return }
                            Task { await ShareActions.showSignIn(share, sheets: shareSheets) }
                        })
                        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    if settings.settings.showPreview {
                        PreviewPane(controller: preview)
                            .frame(minWidth: 240, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if model.isSearching, model.searchTruncated {
                    Divider()
                    Text(String(localized: "More than 10,000 results; refine your search."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                Divider()
                PathBar(model: model)
                OperationsStrip()
            }
            .searchable(text: searchText, placement: .toolbar, prompt: String(localized: "Search"))
            .searchFocused($searchFieldFocused)
            // Debounced: each keystroke restarts the wait. Clearing the field ends the search at once.
            .task(id: searchText.wrappedValue) {
                let text = searchText.wrappedValue
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Only a text search: the field is also cleared when a tag view starts.
                    if case .folder? = model.search?.scope { model.endSearch() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.startSearch(text)
            }
            // A navigation (or Back) ends the search, and a tag view isn't a text search: clear the field.
            .onChange(of: model.search) { _, search in
                if search == nil || search?.scope != .folder(model.currentURL) { searchText.wrappedValue = "" }
            }
        }
        // On the split view, which exists exactly while model and preview do (not on the Group's branches,
        // whose switch from `Color.clear` would fire them around creation). Closing the window stops
        // extraction and rendering for the preview; both calls are idempotent.
        .onAppear { preview.resume() }
        .onDisappear { preview.stop() }
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
                .disabled(!model.history.canGoBack)
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
        .task { await model.reload() }
        .onChange(of: model.currentURL, initial: true) { _, url in storedPath = url.path }
        // Refresh on focus: a network folder isn't watched reliably, so it is listed again whenever its window
        // becomes active. Local folders rely on their watcher. The check uses the last load's cached info, and
        // a listing already in flight is kept (see `refreshOnFocus`).
        .onChange(of: appearsActive) { _, active in
            guard active, model.isOnNetworkVolume else { return }
            Task { await model.refreshOnFocus() }
        }
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
