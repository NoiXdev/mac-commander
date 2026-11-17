import AppKit
import Foundation
import Observation

/// Per-window view model: the current folder, its sorted items, selection and navigation.
///
/// `init` does not touch the disk; the UI calls `reload()` once when the window appears.
@MainActor @Observable
public final class BrowserModel {
    public private(set) var history: NavigationHistory
    public var currentURL: URL { history.current }
    /// Sorted by `settings.settings.sortOrder`; hidden files are filtered by the loader.
    public private(set) var items: [FileItem] = []
    public private(set) var loadError: DirectoryLoadError?
    public private(set) var isLoading = false
    public var selection: Set<URL> = []
    /// Set after a create; the list starts inline editing for it, then sets it back to nil.
    public var pendingRename: URL?

    @ObservationIgnored private let settings: ViewSettingsStore
    @ObservationIgnored private let loader: DirectoryLoader
    @ObservationIgnored private let opener: @MainActor (URL) -> Void
    /// Unsorted items of the last successful load.
    @ObservationIgnored private var loadedItems: [FileItem] = []
    /// Bumped per load: a stale load result never overwrites a newer one.
    @ObservationIgnored private var loadGeneration = 0
    /// Bumped per sort: a stale sort result never overwrites a newer one.
    @ObservationIgnored private var sortGeneration = 0
    @ObservationIgnored private var observedSettings: ViewSettings
    @ObservationIgnored private var watcher: DirectoryWatcher?
    /// Removes the unmount observer when the model goes away.
    @ObservationIgnored private var unmountObservation: NotificationObservation?
    /// Test hook: runs after a listing finishes, before its result is checked for staleness.
    @ObservationIgnored var afterListingHook: (@MainActor (URL) async -> Void)?

    public init(
        start: URL,
        settings: ViewSettingsStore,
        loader: DirectoryLoader = DirectoryLoader(),
        opener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        history = NavigationHistory(start: start)
        self.settings = settings
        self.loader = loader
        self.opener = opener
        observedSettings = settings.settings
        observeSettings()
        observeUnmounts()
    }

    deinit {
        // The unmount observer is removed by `NotificationObservation.deinit`.
        watcher?.cancel()
    }

    // MARK: - Navigation

    /// Navigates to a folder. A symlink to a folder navigates to its target, because the loader
    /// can't list through a symlink. Files and missing paths are ignored.
    public func navigate(to requested: URL) async {
        guard Self.isDirectory(requested) else { return }
        let isSymlink = (try? requested.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        let url = isSymlink ? requested.resolvingSymlinksInPath() : requested
        guard url.standardizedFileURL != currentURL.standardizedFileURL else { return }
        history.visit(url)
        await load()
    }

    public func goBack() async {
        guard history.goBack() != nil else { return }
        await load()
    }

    public func goForward() async {
        guard history.goForward() != nil else { return }
        await load()
    }

    public func goUp() async {
        let current = currentURL.standardizedFileURL
        guard current.path != "/" else { return }
        await navigate(to: current.deletingLastPathComponent())
    }

    public func reload() async {
        await load()
    }

    /// Folders (and symlinks to folders) navigate; anything else, packages included, is opened.
    public func open(_ item: FileItem) async {
        if item.isDirectory || (!item.isPackage && Self.isDirectory(item.url, excludingPackages: true)) {
            await navigate(to: item.url)
        } else {
            opener(item.url)
        }
    }

    /// Lists a subfolder for inline expansion, with the same sorting and filtering as `items`.
    public func children(of url: URL) async throws(DirectoryLoadError) -> [FileItem] {
        let current = settings.settings
        let raw = try await loader.contents(of: url, includeHidden: current.showHiddenFiles)
        return await Self.sort(raw, by: current.sortOrder)
    }

    // MARK: - File operations

    public func createFolder(in directory: URL? = nil) async throws -> URL {
        let parent = directory ?? currentURL
        let historyAtStart = history
        let created = try await Self.offMain { try ItemCreator.createFolder(in: parent) }
        return await didCreate(created, in: parent, historyAtStart: historyAtStart)
    }

    public func createEmptyFile(in directory: URL? = nil) async throws -> URL {
        let parent = directory ?? currentURL
        let historyAtStart = history
        let created = try await Self.offMain { try ItemCreator.createEmptyFile(in: parent) }
        return await didCreate(created, in: parent, historyAtStart: historyAtStart)
    }

    /// Returns the URL as spelled in `items` when the item is in the current folder and no
    /// navigation happened meanwhile; otherwise the renamed URL as is.
    public func rename(_ url: URL, to name: String) async throws(RenameError) -> URL {
        let historyAtStart = history
        let renamed = try await Self.rename(url, to: name)
        let oldPath = Self.canonicalPath(url)
        if let selected = selection.first(where: { Self.canonicalPath($0) == oldPath }) {
            selection.remove(selected)
            selection.insert(renamed)
        }
        guard await reloadIfStillShowing(url.deletingLastPathComponent(), since: historyAtStart) else {
            return renamed
        }
        return itemURL(matching: renamed)
    }

    // MARK: - Loading

    /// Returns whether this load was still the newest one when it finished, i.e. `items` now
    /// reflect its listing.
    @discardableResult
    private func load() async -> Bool {
        loadGeneration += 1
        let generation = loadGeneration

        if !FileManager.default.fileExists(atPath: currentURL.path) {
            history.replaceCurrent(with: PathUtilities.nearestExistingAncestor(of: currentURL))
        }
        let url = currentURL
        let current = settings.settings
        // Watch before listing, so a change during the listing still triggers a reload.
        startWatching(url)
        isLoading = true

        let result: Result<[FileItem], DirectoryLoadError>
        do {
            result = .success(try await loader.contents(of: url, includeHidden: current.showHiddenFiles))
        } catch {
            result = .failure(error)
        }
        await afterListingHook?(url)
        guard generation == loadGeneration else { return false }

        switch result {
        case .success(let raw):
            loadedItems = raw
            loadError = nil
        case .failure(.notFound) where !FileManager.default.fileExists(atPath: url.path):
            // Vanished between the existence check and the listing: fall back again.
            return await load()
        case .failure(let error):
            loadedItems = []
            loadError = error
        }
        await present(loadGeneration: generation)
        guard generation == loadGeneration else { return false }
        isLoading = false
        return true
    }

    /// Sorts `loadedItems` off the main actor and publishes them, unless something newer started.
    private func present(loadGeneration expectedLoad: Int) async {
        sortGeneration += 1
        let generation = sortGeneration
        let sorted = await Self.sort(loadedItems, by: settings.settings.sortOrder)
        guard generation == sortGeneration, expectedLoad == loadGeneration else { return }
        items = sorted
        pruneSelection()
    }

    /// Drops selected entries that disappeared. Entries in the current folder are matched against
    /// `items` by canonical path (the loader may spell the folder differently, e.g. `/private/var`)
    /// and replaced by the item's URL; entries elsewhere (inline-expanded subfolders) must still exist.
    private func pruneSelection() {
        guard !selection.isEmpty else { return }
        let directory = currentURL.resolvingSymlinksInPath().path
        var byName: [String: URL] = [:]
        for item in items { byName[item.url.lastPathComponent] = item.url }
        // Selected entries usually share a few parents: resolve each parent once, not per entry.
        var resolvedParents: [String: String] = [:]
        let pruned = Set(selection.compactMap { url -> URL? in
            let parent = url.deletingLastPathComponent()
            let resolved = resolvedParents[parent.path] ?? {
                let value = parent.resolvingSymlinksInPath().path
                resolvedParents[parent.path] = value
                return value
            }()
            if resolved == directory {
                return byName[url.lastPathComponent]
            }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        })
        if pruned != selection { selection = pruned }
    }

    /// Selects the new item and requests its rename. In the current folder it reloads first and
    /// returns the URL as spelled in `items`. If the user navigated away meanwhile, it returns the
    /// created URL and leaves selection and `pendingRename` alone.
    private func didCreate(_ created: URL, in parent: URL, historyAtStart: NavigationHistory) async -> URL {
        guard history == historyAtStart else { return created }
        var url = created
        if isCurrentDirectory(parent) {
            guard await reloadIfStillShowing(parent, since: historyAtStart) else { return created }
            url = itemURL(matching: created)
        }
        selection = [url]
        pendingRename = url
        return url
    }

    /// Reloads when `directory` is the current folder and no navigation happened since
    /// `historyAtStart`. Returns true only if `items` now show that folder's fresh listing.
    private func reloadIfStillShowing(_ directory: URL, since historyAtStart: NavigationHistory) async -> Bool {
        guard history == historyAtStart, isCurrentDirectory(directory) else { return false }
        guard await load() else { return false }
        return history == historyAtStart && isCurrentDirectory(directory)
    }

    /// For a URL in the current folder: the matching item's URL, or `url` if there is none.
    /// Compares names only, so large folders need no per-item symlink resolution.
    private func itemURL(matching url: URL) -> URL {
        let name = url.lastPathComponent
        return items.first { $0.url.lastPathComponent == name }?.url ?? url
    }

    private func isCurrentDirectory(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path == currentURL.resolvingSymlinksInPath().path
    }

    private func startWatching(_ url: URL) {
        watcher?.cancel()
        watcher = DirectoryWatcher(url: url) { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
    }

    // MARK: - Volumes

    /// The watcher doesn't report an ejected volume, so reload when the volume holding the
    /// current folder unmounts; `load()` then falls back to the nearest existing ancestor.
    private func observeUnmounts() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil
        ) { [weak self] note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in await self?.volumeDidUnmount(volume) }
        }
        unmountObservation = NotificationObservation(center: center, token: token)
    }

    private func volumeDidUnmount(_ volume: URL?) async {
        if let volume {
            let volumePath = volume.standardizedFileURL.path
            let currentPath = currentURL.standardizedFileURL.path
            let prefix = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
            guard currentPath == volumePath || currentPath.hasPrefix(prefix) else { return }
        }
        await load()
    }

    // MARK: - Settings

    private func observeSettings() {
        withObservationTracking {
            _ = settings.settings
        } onChange: { [weak self] in
            // Called before the change is applied; read the new value on the next main-actor turn.
            Task { @MainActor in await self?.settingsDidChange() }
        }
    }

    private func settingsDidChange() async {
        observeSettings()
        let old = observedSettings
        let new = settings.settings
        observedSettings = new
        if new.showHiddenFiles != old.showHiddenFiles {
            // The loader filters hidden files, so they need a fresh listing.
            await load()
        } else if new.sortOrder != old.sortOrder {
            await present(loadGeneration: loadGeneration)
        }
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL, excludingPackages: Bool = false) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
            values.isDirectory == true
        else { return false }
        return !(excludingPackages && values.isPackage == true)
    }

    /// The path with its parent folder's symlinks resolved; the item itself may be a symlink.
    private static func canonicalPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    @concurrent
    private static func sort(_ items: [FileItem], by order: FileSortOrder) async -> [FileItem] {
        order.sorted(items)
    }

    @concurrent
    private static func offMain(_ work: @Sendable () throws -> URL) async throws -> URL {
        try work()
    }

    @concurrent
    private static func rename(_ url: URL, to name: String) async throws(RenameError) -> URL {
        try ItemRenamer.rename(url, to: name)
    }
}

/// Removes a block-based notification observer when released.
private final class NotificationObservation: @unchecked Sendable {
    // @unchecked: both properties are immutable, and NotificationCenter is thread-safe.
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter, token: any NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}
