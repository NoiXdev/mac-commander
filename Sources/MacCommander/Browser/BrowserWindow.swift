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
    private let goToFolderState = State(initialValue: false)
    private var model: BrowserModel? {
        get { modelState.wrappedValue }
        nonmutating set { modelState.wrappedValue = newValue }
    }
    private var showGoToFolder: Binding<Bool> { goToFolderState.projectedValue }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard model == nil else { return }
            model = BrowserModel(start: Self.startURL(storedPath: storedPath), settings: settings, operations: operations)
        }
    }

    private func content(_ model: BrowserModel) -> some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            VStack(spacing: 0) {
                FileListView(model: model, settings: settings, clipboard: clipboard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// The restored folder, or home when nothing is stored or the folder is gone.
    private static func startURL(storedPath: String) -> URL {
        var isDirectory: ObjCBool = false
        if !storedPath.isEmpty,
            FileManager.default.fileExists(atPath: storedPath, isDirectory: &isDirectory), isDirectory.boolValue
        {
            return URL(fileURLWithPath: storedPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func displayName(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            ?? FileManager.default.displayName(atPath: url.path)
    }
}

enum BrowserActions {
    @MainActor
    static func newFolder(_ model: BrowserModel, in directory: URL? = nil) async {
        do { _ = try await model.createFolder(in: directory) } catch { show(error) }
    }

    @MainActor
    static func newFile(_ model: BrowserModel, in directory: URL? = nil) async {
        do { _ = try await model.createEmptyFile(in: directory) } catch { show(error) }
    }

    @MainActor
    private static func show(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}
