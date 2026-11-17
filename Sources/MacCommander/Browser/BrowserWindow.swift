import AppKit
import MacCommanderCore
import SwiftUI

// `@Entry` and `@State` are macros whose plugin is missing under Command Line Tools, so the
// focused-value keys are spelled out and `State` is used as a plain property.
private struct BrowserModelKey: FocusedValueKey { typealias Value = BrowserModel }
private struct GoToFolderPresentedKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    var browserModel: BrowserModel? {
        get { self[BrowserModelKey.self] }
        set { self[BrowserModelKey.self] = newValue }
    }
    var goToFolderPresented: Binding<Bool>? {
        get { self[GoToFolderPresentedKey.self] }
        set { self[GoToFolderPresentedKey.self] = newValue }
    }
}

/// One browser window: sidebar, file list, path bar and toolbar.
struct BrowserWindow: View {
    @Environment(ViewSettingsStore.self) private var settings
    @Environment(FileOperationCenter.self) private var operations
    @Environment(FileClipboard.self) private var clipboard
    @SceneStorage("currentFolderPath") private var storedPath = ""
    /// True while the window is key (or the app's active window); see the refresh on focus below.
    @Environment(\.appearsActive) private var appearsActive
    private let modelState = State<BrowserModel?>(initialValue: nil)
    private let previewState = State<PreviewController?>(initialValue: nil)
    private let goToFolderState = State(initialValue: false)
    /// The Finder name of a folder, resolved off the main actor; the title shows it once it matches.
    private let titleState = State<(url: URL, name: String)?>(initialValue: nil)
    private var model: BrowserModel? {
        get { modelState.wrappedValue }
        nonmutating set { modelState.wrappedValue = newValue }
    }
    private var preview: PreviewController? {
        get { previewState.wrappedValue }
        nonmutating set { previewState.wrappedValue = newValue }
    }
    private var showGoToFolder: Binding<Bool> { goToFolderState.projectedValue }
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
            self.model = model
            preview = PreviewController(model: model, settings: settings)
        }
    }

    private func content(_ model: BrowserModel, preview: PreviewController) -> some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // The list stays the split view's first child whether or not the pane is shown, so it keeps
                // its identity (controller, scroll position, selection) when the pane toggles.
                HSplitView {
                    FileListView(model: model, settings: settings, clipboard: clipboard)
                        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                    if settings.settings.showPreview {
                        PreviewPane(controller: preview)
                            .frame(minWidth: 240, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                Divider()
                PathBar(model: model)
                OperationsStrip()
            }
        }
        // On the split view, which exists exactly while model and preview do (not on the Group's branches,
        // whose switch from `Color.clear` would fire them around creation). Closing the window stops
        // extraction and rendering for the preview; both calls are idempotent.
        .onAppear { preview.resume() }
        .onDisappear { preview.stop() }
        // The last path component at once (no disk access), the localized name once it's resolved.
        .navigationTitle(title(for: model.currentURL))
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
                // Archives are read-only.
                .disabled(model.archiveLocation != nil)
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
        .sheet(isPresented: showGoToFolder) { GoToFolderSheet(model: model) }
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

    private func title(for url: URL) -> String {
        if let resolvedTitle, resolvedTitle.url == url { return resolvedTitle.name }
        return url.path == "/" ? "/" : url.lastPathComponent
    }
}

enum BrowserActions {
    @MainActor
    static func newFolder(_ model: BrowserModel, in directory: URL? = nil) async {
        // Archives are read-only (the menus are disabled there; this covers a shortcut that slips through).
        guard model.archiveLocation == nil else { return NSSound.beep() }
        do { _ = try await model.createFolder(in: directory) } catch { show(error) }
    }

    @MainActor
    static func newFile(_ model: BrowserModel, in directory: URL? = nil) async {
        guard model.archiveLocation == nil else { return NSSound.beep() }
        do { _ = try await model.createEmptyFile(in: directory) } catch { show(error) }
    }

    @MainActor
    private static func show(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}
