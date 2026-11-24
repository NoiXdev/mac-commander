import AppKit
import MacCommanderCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    let model: BrowserModel
    let shareSheets: ShareSheets
    @Environment(FavoritesStore.self) private var favorites
    @Environment(PreferencesStore.self) private var preferences
    @Environment(OpenRequestRouter.self) private var router
    private let volumesState = State<[VolumeInfo]>(initialValue: [])
    private let missingState = State<SidebarLocation?>(initialValue: nil)
    /// Whether the iCloud Drive folder exists (it doesn't when not signed in); checked off the main thread.
    private let iCloudExistsState = State(initialValue: false)
    /// The cloud accounts' folders (OneDrive, Google Drive, …), one per account.
    private let cloudState = State<[CloudLocation]>(initialValue: [])
    /// Bundle identifiers of the running apps, for the cloud accounts' status.
    private let runningAppsState = State<Set<String>>(initialValue: [])
    /// The sidebar's window, for the conflict dialog and alerts of drops onto rows.
    private let windowState = State(initialValue: WindowBox())
    private var volumes: [VolumeInfo] {
        get { volumesState.wrappedValue }
        nonmutating set { volumesState.wrappedValue = newValue }
    }
    private var missing: SidebarLocation? {
        get { missingState.wrappedValue }
        nonmutating set { missingState.wrappedValue = newValue }
    }
    private var iCloudExists: Bool {
        get { iCloudExistsState.wrappedValue }
        nonmutating set { iCloudExistsState.wrappedValue = newValue }
    }
    private var cloud: [CloudLocation] {
        get { cloudState.wrappedValue }
        nonmutating set { cloudState.wrappedValue = newValue }
    }
    private var runningApps: Set<String> {
        get { runningAppsState.wrappedValue }
        nonmutating set { runningAppsState.wrappedValue = newValue }
    }

    /// The local iCloud Drive folder.
    private static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)

    private func isShown(_ section: SidebarSection) -> Bool {
        !preferences.preferences.hiddenSidebarSections.contains(section)
    }

    var body: some View {
        List {
            if isShown(.favorites) { favoritesSection }
            if isShown(.iCloud), iCloudExists || !cloud.isEmpty { cloudSection }
            if isShown(.locations) { locationsSection }
            if isShown(.network) { NetworkSection(model: model, sheets: shareSheets) }
            if isShown(.tags) { TagsSection(model: model) }
        }
        .listStyle(.sidebar)
        .background(WindowReader(box: windowState.wrappedValue))
        .onAppear { Task { await favorites.refreshExistence() } }
        .task { iCloudExists = await PathQueries.info(Self.iCloudDrive).isDirectory }
        .task { await observeCloud() }
        .task {
            volumes = await VolumeProvider.localVolumes()
            await observeVolumes()
        }
        .alert(
            L10n.format("sidebar.favorites.missing", "“%@” can't be found. Remove it from Favorites?", missing?.name ?? ""),
            isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })
        ) {
            Button(L10n.string("sidebar.favorites.missing.remove", "Remove"), role: .destructive) {
                if let missing { favorites.remove(missing.url) }
            }
            Button(L10n.string("sidebar.favorites.missing.cancel", "Cancel"), role: .cancel) {}
        }
    }

    private var favoritesSection: some View {
        Section {
            ForEach(favorites.favorites) { location in
                row(name: location.name, url: location.url, exists: location.exists)
                    .onTapGesture { select(location) }
                    .onDrop(of: FolderDropDelegate.types, delegate: dropDelegate(into: location.url, enabled: location.exists))
                    .contextMenu {
                        if location.exists { openInNewTabButton(location.url) }
                        Button(L10n.string("sidebar.favorites.removeFromSidebar", "Remove from Sidebar")) { favorites.remove(location.url) }
                    }
            }
            .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
            // Between rows: add the dropped folders as favorites (onto a row: see `FolderDropDelegate`).
            .onInsert(of: [.fileURL]) { index, providers in drop(providers, at: index) }
        } header: {
            // Also adds favorites (at the end), in case drops between rows land on a row instead.
            L10n.text("sidebar.section.favorites", "Favorites")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    drop(providers, at: favorites.favorites.count)
                    return true
                }
        }
    }

    /// iCloud Drive, then one row per cloud account folder (`CloudStorageProvider`) with its status: active,
    /// app not running (nothing syncs), or not connected (a folder left behind, shown dimmed). Accounts are added
    /// in the provider's own app (for OneDrive: Settings ▸ Account ▸ Add an Account) and show up by themselves.
    private var cloudSection: some View {
        Section(L10n.string("sidebar.section.cloud", "Cloud")) {
            if iCloudExists {
                row(name: L10n.string("sidebar.cloud.iCloudDrive", "iCloud Drive"), url: Self.iCloudDrive, exists: true, symbol: "icloud")
                    .onTapGesture { Task { await model.navigate(to: Self.iCloudDrive) } }
                    .onDrop(of: FolderDropDelegate.types, delegate: dropDelegate(into: Self.iCloudDrive, enabled: true))
                    .contextMenu { openInNewTabButton(Self.iCloudDrive) }
            }
            ForEach(cloud) { location in
                let status = location.status { runningApps.contains($0) }
                Label {
                    Text(location.name).lineLimit(1)
                } icon: {
                    Self.cloudSymbol(status)
                }
                .foregroundStyle(status == .disconnected ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(Self.cloudTooltip(location, status: status))
                .onTapGesture { Task { await model.navigate(to: location.url) } }
                .onDrop(of: FolderDropDelegate.types, delegate: dropDelegate(into: location.url, enabled: true))
                .contextMenu {
                    openInNewTabButton(location.url)
                    if status != .active, let app = location.appBundleID,
                        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
                    {
                        Button(L10n.format("sidebar.cloud.openApp", "Open %@", location.provider)) {
                            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
                        }
                    }
                }
            }
        }
    }

    private func openInNewTabButton(_ url: URL) -> some View {
        Button(L10n.string("sidebar.menu.openInNewTab", "Open in New Tab")) {
            router.openNewTab([OpenRequest(folder: url, selection: [])], joining: windowState.wrappedValue.window)
        }
    }

    @ViewBuilder
    private static func cloudSymbol(_ status: CloudAccountStatus) -> some View {
        switch status {
        case .active: Image(systemName: "circle.fill").foregroundStyle(.green)
        case .appNotRunning: Image(systemName: "circle").foregroundStyle(.secondary)
        case .disconnected: Image(systemName: "icloud.slash").foregroundStyle(.red)
        }
    }

    private static func cloudTooltip(_ location: CloudLocation, status: CloudAccountStatus) -> String {
        switch status {
        case .active:
            L10n.string("sidebar.cloud.active", "Connected")
        case .appNotRunning:
            L10n.format("sidebar.cloud.appNotRunning", "%@ isn't running: changes don't sync.", location.provider)
        case .disconnected:
            L10n.format("sidebar.cloud.disconnected", "Not connected: macOS doesn't know this folder as a %@ account. It may be left over from a removed account.", location.provider)
        }
    }

    /// Lists the cloud accounts, and again whenever an account folder is added or removed or an app starts or
    /// quits (starting a provider's app can connect its account).
    private func observeCloud() async {
        let workspace = NSWorkspace.shared
        runningApps = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        cloud = await CloudStorageProvider.locations()
        let stream = AsyncStream<Void> { continuation in
            let watcher = DirectoryWatcher(url: CloudStorageProvider.folder) { continuation.yield() }
            let center = workspace.notificationCenter
            // A provider's app registers its account a moment after it starts: checked again 5 s later.
            let tokens = [
                center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
                    continuation.yield()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { continuation.yield() }
                },
                center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
                    continuation.yield()
                },
            ]
            let box = TokenBox(tokens)
            continuation.onTermination = { _ in
                watcher?.cancel()
                box.tokens.forEach { center.removeObserver($0) }
            }
        }
        for await _ in stream {
            runningApps = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
            cloud = await CloudStorageProvider.locations()
        }
    }

    private var locationsSection: some View {
        Section(L10n.string("sidebar.section.locations", "Locations")) {
            ForEach(volumes) { volume in
                HStack {
                    row(name: volume.name, url: volume.url, exists: true, symbol: volume.isBoot ? "internaldrive" : "externaldrive")
                    if volume.isEjectable {
                        Button {
                            eject(volume)
                        } label: {
                            Image(systemName: "eject")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.string("sidebar.locations.eject", "Eject"))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.navigate(to: volume.url) } }
                .onDrop(of: FolderDropDelegate.types, delegate: dropDelegate(into: volume.url, enabled: true))
            }
        }
    }

    private func row(name: String, url: URL, exists: Bool, symbol: String? = nil) -> some View {
        Label(name, systemImage: symbol ?? Self.symbol(for: url))
            .foregroundStyle(exists ? Color.primary : Color.secondary)
            .opacity(exists ? 1 : 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func eject(_ volume: VolumeInfo) {
        Task {
            do {
                try await Self.unmount(volume.url)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = L10n.format("sidebar.locations.ejectFailed", "The volume “%@” couldn't be ejected.", volume.name)
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Unmounting can block for a long time, so it runs off the main actor.
    @concurrent
    private static func unmount(_ url: URL) async throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }

    /// Navigates (the model checks the folder off the main actor, and a newer click wins), or offers to
    /// remove the favorite when nothing is there. Never for a path on a saved network share: one that isn't
    /// connected shows its Disconnected placeholder instead, and a folder missing on a connected one may be
    /// back after the next reconnect. The sidebar's grey state is refreshed alongside.
    private func select(_ location: SidebarLocation) {
        Task {
            async let refreshed: Void = favorites.refreshExistence()
            if await model.navigate(to: location.url) == .missing, model.shareResolver?(location.url) == nil {
                missing = location
            }
            await refreshed
        }
    }

    private func dropDelegate(into destination: URL, enabled: Bool) -> FolderDropDelegate {
        FolderDropDelegate(destination: destination, enabled: enabled, model: model, window: windowState.wrappedValue)
    }

    private func drop(_ providers: [NSItemProvider], at index: Int) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                // The completion runs off the main thread, but check through `PathQueries` all the same.
                Task { @MainActor in
                    guard await PathQueries.info(url).isDirectory else { return }
                    favorites.add(url, at: index)
                }
            }
        }
    }

    private func observeVolumes() async {
        let center = NSWorkspace.shared.notificationCenter
        let names = VolumeProvider.didChangeNotifications
        let stream = AsyncStream<Void> { continuation in
            let tokens = names.map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { _ in continuation.yield() }
            }
            let box = TokenBox(tokens)
            continuation.onTermination = { _ in box.tokens.forEach { center.removeObserver($0) } }
        }
        for await _ in stream { volumes = await VolumeProvider.localVolumes() }
    }

    private static func symbol(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        switch url.standardizedFileURL.path {
        case home: return "house"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Downloads": return "arrow.down.circle"
        case "/Applications": return "square.grid.2x2"
        default: return "folder"
        }
    }
}

/// Moves or copies files dropped onto a sidebar row (a favorite folder, iCloud Drive or a volume) into that
/// folder, with the list's rules (`DropPolicy`: move on the same volume, copy across volumes, ⌥ copy, ⌘ move).
/// While hovering, the sources are read from the drag pasteboard, since item providers only load
/// asynchronously; the drop itself loads them from the item providers.
///
/// Entries dragged out of an archive (`archiveEntries`, checked first) are extracted into the folder; copy
/// is the only operation. Their payload is read synchronously from the drag pasteboard
/// (`NSPasteboard(name: .drag)`) rather than through `NSItemProvider`: the type isn't declared in Info.plist,
/// and the pasteboard is what the hover check reads anyway. That works for drags from any MacCommander window.
/// Rows are real folders (favorites are only ever added as existing folders, volumes are mount points, iCloud
/// Drive is shown only when it exists), so archive entries are accepted without a path check.
@MainActor
private struct FolderDropDelegate: DropDelegate {
    /// The types the rows register for: archive entries first, then files.
    static let types: [UTType] = [.archiveEntries, .fileURL]

    let destination: URL
    /// False for a missing favorite: it refuses drops.
    let enabled: Bool
    let model: BrowserModel
    let window: WindowBox

    func validateDrop(info: DropInfo) -> Bool {
        guard enabled else { return false }
        if isArchiveDrag { return true }
        // The mode isn't checked here: it is computed off the main actor, and `dropUpdated` shows the
        // refusal (forbidden) until it is known; the drop re-checks.
        return info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isArchiveDrag { return DropProposal(operation: .copy) }
        switch currentMode() {
        case .copy?: return DropProposal(operation: .copy)
        case .move?: return DropProposal(operation: .move)
        case nil: return DropProposal(operation: .forbidden)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard enabled else { return false }
        if isArchiveDrag {
            guard let payload = ArchiveDragPayload(pasteboard: NSPasteboard(name: .drag)) else {
                return false
            }
            let destination = destination
            let model = model
            let window = window
            Task {
                await FileActions.extract(
                    payload.entries, from: payload.archive, into: destination, model: model, window: window.window)
            }
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        // The keys held at drop time; the URLs arrive later.
        let modifiers = FileActions.currentDropModifiers()
        let destination = destination
        let model = model
        let window = window
        DroppedURLCollector.load(providers) { sources in
            Task {
                guard let mode = await FileActions.dropMode(for: sources, into: destination, modifiers: modifiers)
                else { return NSSound.beep() }
                await FileActions.transfer(sources, into: destination, mode: mode, model: model, window: window.window)
            }
        }
        return true
    }

    /// The drag carries entries of an archive (a type check on the drag pasteboard).
    private var isArchiveDrag: Bool { ArchiveDragPayload.isOn(NSPasteboard(name: .drag)) }

    /// Cached per drag, destination and modifier keys: `dropUpdated` runs on every mouse move.
    private func currentMode() -> TransferMode? {
        guard enabled else { return nil }
        return FileActions.hoverDropMode(on: NSPasteboard(name: .drag), into: destination)
    }
}

/// Loads the file URLs of several item providers and hands all of them over at once on the main actor
/// (one transfer, one conflict dialog, one undo step). Providers that yield no URL are left out.
@MainActor
private final class DroppedURLCollector {
    private var urls: [URL?]
    private var pending: Int
    private let completion: @MainActor ([URL]) -> Void

    private init(count: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        urls = Array(repeating: nil, count: count)
        pending = count
        self.completion = completion
    }

    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let collector = DroppedURLCollector(count: providers.count, completion: completion)
        for (index, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in collector.received(url, at: index) }
            }
        }
    }

    private func received(_ url: URL?, at index: Int) {
        urls[index] = url?.isFileURL == true ? url : nil
        pending -= 1
        if pending == 0 {
            let sources = urls.compactMap { $0 }
            if !sources.isEmpty { completion(sources) }
        }
    }
}

/// Holds the window a SwiftUI view is in (set by `WindowReader`).
@MainActor
final class WindowBox {
    weak var window: NSWindow?
}

/// An invisible view that records its window in `box`.
struct WindowReader: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.box = box
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.box = box
        box.window = view.window
    }

    final class ReaderView: NSView {
        var box: WindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }
}

/// Carries notification tokens into a `@Sendable` termination handler.
private final class TokenBox: @unchecked Sendable {
    // @unchecked: immutable after init, and only used to remove observers (thread-safe).
    let tokens: [any NSObjectProtocol]
    init(_ tokens: [any NSObjectProtocol]) { self.tokens = tokens }
}
