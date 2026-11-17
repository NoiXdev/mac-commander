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
    private let modelState = State<BrowserModel?>(initialValue: nil)
    private let previewState = State<PreviewController?>(initialValue: nil)
    private let goToFolderState = State(initialValue: false)
    private var model: BrowserModel? {
        get { modelState.wrappedValue }
        nonmutating set { modelState.wrappedValue = newValue }
    }
    private var preview: PreviewController? {
        get { previewState.wrappedValue }
        nonmutating set { previewState.wrappedValue = newValue }
    }
    private var showGoToFolder: Binding<Bool> { goToFolderState.projectedValue }

    var body: some View {
        Group {
            if let model, let preview {
                content(model, preview: preview)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if model != nil {
                preview?.resume()
                return
            }
            let model = BrowserModel(start: Self.startURL(storedPath: storedPath), settings: settings, operations: operations)
            self.model = model
            preview = PreviewController(model: model, settings: settings)
        }
        // Closing the window: stop extraction and rendering for the preview.
        .onDisappear { preview?.stop() }
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
        .navigationTitle(Self.displayName(of: model.currentURL))
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
    }

    /// The restored folder (also a folder inside an archive), its nearest existing ancestor when it is gone,
    /// or home when nothing is stored.
    private static func startURL(storedPath: String) -> URL {
        guard !storedPath.isEmpty else { return FileManager.default.homeDirectoryForCurrentUser }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: storedPath, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: storedPath, isDirectory: true)
        }
        // A few `stat`s, cheap.
        let url = URL(fileURLWithPath: storedPath, isDirectory: false)
        if ArchivePath.split(url) != nil { return url }
        return PathUtilities.nearestExistingAncestor(of: url)
    }

    static func displayName(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            ?? FileManager.default.displayName(atPath: url.path)
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
