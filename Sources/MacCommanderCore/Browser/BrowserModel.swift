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
    /// The folder `items` were listed from, published together with `items`; nil while nothing
    /// is listed or the listing failed. Lags behind `currentURL` until a new listing arrives.
    public private(set) var listedURL: URL?
    /// The archive location shown, nil in ordinary folders. Published together with `items` and
    /// `listedURL` (also after a failed listing of an archive, e.g. one that needs a password), so
    /// it lags behind `currentURL` while loading. The UI derives read-only mode from it.
    public private(set) var archiveLocation: ArchiveLocation?
    public private(set) var loadError: DirectoryLoadError?
    public private(set) var isLoading = false
    public var selection: Set<URL> = []
    /// Set after a create; the list starts inline editing for it, then sets it back to nil.
    public var pendingRename: URL?

    /// The app-wide operation center: undo history and operation notifications.
    @ObservationIgnored public let operations: FileOperationCenter
    @ObservationIgnored private let settings: ViewSettingsStore
    @ObservationIgnored private let loader: DirectoryLoader
    @ObservationIgnored private let opener: @MainActor (URL) -> Void
    @ObservationIgnored private let catalog: ArchiveCatalog
    /// Unsorted items of the last load, and the folder they came from (nil after a failure).
    @ObservationIgnored private var loadedItems: [FileItem] = []
    @ObservationIgnored private var loadedURL: URL?
    /// The archive location of the last load, published with `loadedItems`.
    @ObservationIgnored private var loadedLocation: ArchiveLocation?
    /// An archive entered by `open(_:)` (double-click / ⌘↓): if bsdtar can't read it, the model
    /// returns and hands it to `opener` instead. nil for Browse Contents, Go to Folder and history.
    @ObservationIgnored private var pendingOpenFallback: URL?
    /// The folder the newest load is listing; nil when no load is in flight.
    @ObservationIgnored private var inFlightURL: URL?
    /// Set when the folder changed while a load of it was in flight: one more load follows.
    @ObservationIgnored private var needsReload = false
    /// Bumped per load: a stale load result never overwrites a newer one.
    @ObservationIgnored private var loadGeneration = 0
    /// Bumped per sort: a stale sort result never overwrites a newer one.
    @ObservationIgnored private var sortGeneration = 0
    @ObservationIgnored private var observedSettings: ViewSettings
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var watchedURL: URL?
    @ObservationIgnored private var watchedIdentity: FolderIdentity?
    /// Removes the unmount observer when the model goes away.
    @ObservationIgnored private var unmountObservation: NotificationObservation?
    /// Removes the folders-changed observer when the model goes away.
    @ObservationIgnored private var foldersObservation: NotificationObservation?
    /// Test hook: runs after a listing finishes, before its result is checked for staleness.
    @ObservationIgnored var afterListingHook: (@MainActor (URL) async -> Void)?

    public init(
        start: URL,
        settings: ViewSettingsStore,
        loader: DirectoryLoader = DirectoryLoader(),
        opener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        operations: FileOperationCenter = FileOperationCenter(),
        catalog: ArchiveCatalog = .shared
    ) {
        history = NavigationHistory(start: start)
        self.settings = settings
        self.loader = loader
        self.opener = opener
        self.operations = operations
        self.catalog = catalog
        observedSettings = settings.settings
        observeSettings()
        observeUnmounts()
        observeFolderChanges()
    }

    deinit {
        // The unmount observer is removed by `NotificationObservation.deinit`.
        watcher?.cancel()
    }

    // MARK: - Navigation

    /// Navigates to a folder. A symlink to a folder navigates to its target, because the loader
    /// can't list through a symlink. Also navigates into archives: a pure archive file
    /// (`ArchiveFormats.isArchive`; a symlink to one keeps its own path), and any virtual path
    /// inside an archive (Go to Folder `…/a.zip/img`). Other files and missing paths are ignored.
    public func navigate(to requested: URL) async {
        await navigate(to: requested, anyBrowsable: false, openFallback: false)
    }

    /// "Browse Contents": navigates into any browsable file (pure archives and containers such as
    /// `.docx`). Unreadable files show a load error. Items inside an archive are ignored, since
    /// nested archives aren't browsable.
    public func browseContents(_ item: FileItem) async {
        guard !item.isDirectory, let location = ArchivePath.split(item.url), location.inner.isEmpty else { return }
        await navigate(to: item.url, anyBrowsable: true, openFallback: false)
    }

    /// `anyBrowsable` skips the extension check for an archive file; `openFallback` makes an
    /// unreadable archive go to `opener` instead of showing an error.
    private func navigate(to requested: URL, anyBrowsable: Bool, openFallback: Bool) async {
        let url: URL
        if Self.isDirectory(requested) {
            let isSymlink = (try? requested.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            url = isSymlink ? requested.resolvingSymlinksInPath() : requested
        } else if let location = ArchivePath.split(requested) {
            // The archive file itself needs an archive extension, unless it's browsed explicitly or
            // reached from inside the same archive (goUp, breadcrumbs).
            let isAccepted = !location.inner.isEmpty || anyBrowsable
                || ArchiveFormats.isArchive(requested)
                || ArchivePath.split(currentURL)?.archive == location.archive
            guard isAccepted else { return }
            url = requested
        } else {
            return
        }
        guard url.standardizedFileURL != currentURL.standardizedFileURL else { return }
        pendingOpenFallback = openFallback ? url : nil
        history.visit(url)
        clearSelection()
        await load()
    }

    public func goBack() async {
        guard history.goBack() != nil else { return }
        pendingOpenFallback = nil
        clearSelection()
        await load()
    }

    public func goForward() async {
        guard history.goForward() != nil else { return }
        pendingOpenFallback = nil
        clearSelection()
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

    /// Folders (and symlinks to folders) navigate; pure archives (`ArchiveFormats.isArchive`) open
    /// as folders, falling back to `opener` if bsdtar can't read them; anything else, packages
    /// included, is opened. Inside an archive, folders navigate and files are left alone: opening
    /// an archive entry means extracting it first, which the UI does.
    public func open(_ item: FileItem) async {
        if ArchivePath.split(currentURL) != nil {
            if item.isDirectory { await navigate(to: item.url) }
        } else if item.isDirectory || (!item.isPackage && Self.isDirectory(item.url, excludingPackages: true)) {
            await navigate(to: item.url)
        } else if ArchiveFormats.isArchive(item.url) {
            await navigate(to: item.url, anyBrowsable: false, openFallback: true)
        } else {
            opener(item.url)
        }
    }

    /// Lists a subfolder for inline expansion, with the same sorting and filtering as `items`.
    /// Virtual paths inside an archive are listed from the archive catalog.
    public func children(of url: URL) async throws(DirectoryLoadError) -> [FileItem] {
        let current = settings.settings
        let raw: [FileItem]
        if let location = ArchivePath.split(url) {
            do {
                raw = try await catalog.items(in: location.inner, of: location.archive, includeHidden: current.showHiddenFiles)
            } catch {
                throw Self.loadError(error, archive: location.archive)
            }
        } else {
            raw = try await loader.contents(of: url, includeHidden: current.showHiddenFiles)
        }
        return await Self.sort(raw, by: current.sortOrder)
    }

    /// Remembers `password` for the current archive (for this app session) and lists it again.
    public func providePassword(_ password: String) async {
        guard let location = ArchivePath.split(currentURL) else { return }
        await catalog.setPassword(password, for: location.archive)
        await load()
    }

    // MARK: - File operations

    /// Throws `CocoaError(.fileWriteNoPermission)` inside an archive, which is read-only.
    public func createFolder(in directory: URL? = nil) async throws -> URL {
        let parent = directory ?? currentURL
        try refuseWritesInArchive(parent)
        let historyAtStart = history
        let created = try await Self.offMain { try ItemCreator.createFolder(in: parent) }
        operations.recordCreated(created, isFolder: true)
        return await didCreate(created, in: parent, historyAtStart: historyAtStart)
    }

    /// Throws `CocoaError(.fileWriteNoPermission)` inside an archive, which is read-only.
    public func createEmptyFile(in directory: URL? = nil) async throws -> URL {
        let parent = directory ?? currentURL
        try refuseWritesInArchive(parent)
        let historyAtStart = history
        let created = try await Self.offMain { try ItemCreator.createEmptyFile(in: parent) }
        operations.recordCreated(created, isFolder: false)
        return await didCreate(created, in: parent, historyAtStart: historyAtStart)
    }

    /// Returns the URL as spelled in `items` when the item is in the current folder and no
    /// navigation happened meanwhile; otherwise the renamed URL as is. Inside an archive it throws
    /// `.underlying` with the `CocoaError(.fileWriteNoPermission)` text (the error type is fixed).
    public func rename(_ url: URL, to name: String) async throws(RenameError) -> URL {
        do {
            try refuseWritesInArchive(url.deletingLastPathComponent())
        } catch {
            throw .underlying(error.localizedDescription)
        }
        let historyAtStart = history
        let renamed = try await Self.rename(url, to: name)
        operations.recordRename(from: url, to: renamed)
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

    /// After an operation: when any of `urls` is in the current folder (and no navigation happened
    /// meanwhile), reloads and selects them, spelled as in `items`.
    public func selectAfterOperation(_ urls: [URL]) async {
        let historyAtStart = history
        let inFolder = urls.filter { isCurrentDirectory($0.deletingLastPathComponent()) }
        guard !inFolder.isEmpty else { return }
        guard await reloadIfStillShowing(currentURL, since: historyAtStart) else { return }
        selection = Set(inFolder.map { itemURL(matching: $0) })
    }

    /// Shows a real file or folder in the list: navigates to its parent folder (unless that is the current
    /// folder already) and selects it, spelled as in `items`. Targets inside an archive and missing targets
    /// are ignored. Checks the target with a few `lstat`s on the main actor, like `navigate`. Returns false when ignored (the UI beeps), true otherwise.
    @discardableResult
    public func reveal(_ url: URL) async -> Bool {
        let target = url.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        // lstat: a broken symlink is still an item in the list. `split` of a real file is the file itself
        // (an archive with an empty inner path), so the parent tells whether the target is inside an archive.
        var info = stat()
        guard lstat(target.path, &info) == 0, ArchivePath.split(parent) == nil else { return false }
        if !isCurrentDirectory(parent) {
            await navigate(to: parent)
            guard isCurrentDirectory(parent) else { return true }
        }
        await selectAfterOperation([target])
        return true
    }

    /// Archives are read-only; the UI disables writes there, this is the model's own guard.
    /// `ArchivePath.split` is a few `stat`s, cheap enough for the main actor.
    private func refuseWritesInArchive(_ folder: URL) throws(CocoaError) {
        if archiveLocation != nil || ArchivePath.split(folder) != nil {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    // MARK: - Loading

    /// Returns whether this load was still the newest one when it finished, i.e. `items` now
    /// reflect its listing.
    @discardableResult
    private func load() async -> Bool {
        loadGeneration += 1
        let generation = loadGeneration
        // This listing starts after any change reported so far.
        needsReload = false

        // Split first: a virtual path inside an archive doesn't exist on disk. A vanished archive
        // splits to nil and falls back like a vanished folder. (A few `stat`s, cheap.)
        var location = ArchivePath.split(currentURL)
        if location == nil, !FileManager.default.fileExists(atPath: currentURL.path) {
            history.replaceCurrent(with: PathUtilities.nearestExistingAncestor(of: currentURL))
            clearSelection()
            location = ArchivePath.split(currentURL)
        }
        let url = currentURL
        let current = settings.settings
        // Watch before listing, so a change during the listing still triggers a reload.
        // In an archive the archive file itself is watched.
        startWatching(location?.archive ?? url, isArchive: location != nil)
        inFlightURL = url
        isLoading = true

        let result: Result<ListedItems, ListingError>
        if let location {
            do throws(ArchiveError) {
                result = .success(try await Self.listArchive(location, catalog: catalog, includeHidden: current.showHiddenFiles))
            } catch {
                result = .failure(.archive(error))
            }
        } else {
            do throws(DirectoryLoadError) {
                let raw = try await loader.contents(of: url, includeHidden: current.showHiddenFiles)
                result = .success(ListedItems(items: raw, inner: nil))
            } catch {
                result = .failure(.folder(error))
            }
        }
        await afterListingHook?(url)
        guard generation == loadGeneration else { return false }
        let openFallback = pendingOpenFallback.map { $0.standardizedFileURL == url.standardizedFileURL } ?? false
        pendingOpenFallback = nil

        switch result {
        case .success(let listed):
            var listedURL = url
            var listedLocation = location
            if let location, let inner = listed.inner, inner != location.inner {
                // The folder isn't in the archive: show the deepest one that is.
                listedURL = ArchivePath.url(archive: location.archive, inner: inner)
                listedLocation = ArchiveLocation(archive: location.archive, inner: inner)
                history.replaceCurrent(with: listedURL)
                clearSelection()
            }
            loadedItems = listed.items
            loadedURL = listedURL
            loadedLocation = listedLocation
            loadError = nil
        case .failure(.folder(.notFound)) where !FileManager.default.fileExists(atPath: url.path):
            // Vanished between the existence check and the listing: fall back again.
            return await load()
        case .failure(.archive) where location.map({ !FileManager.default.fileExists(atPath: $0.archive.path) }) == true:
            // The archive vanished during the listing: fall back to an existing folder.
            return await load()
        case .failure(.archive(.cancelled)):
            // The calling task was cancelled; leave the shown items alone.
            isLoading = false
            inFlightURL = nil
            return false
        case .failure(.archive(.unsupported)) where openFallback, .failure(.archive(.unreadable)) where openFallback:
            // Opened by double-click but bsdtar can't read it: go back and let the default app
            // handle it (Archive Utility shows its own error if it can't either).
            if history.goBack() == nil {
                history.replaceCurrent(with: url.deletingLastPathComponent())
            }
            clearSelection()
            opener(url)
            return await load()
        case .failure(let error):
            loadedItems = []
            loadedURL = nil
            loadedLocation = location
            switch error {
            case .folder(let error): loadError = error
            case .archive(let error): loadError = Self.loadError(error, archive: location?.archive ?? url)
            }
        }
        await present(loadGeneration: generation)
        guard generation == loadGeneration else { return false }
        isLoading = false
        inFlightURL = nil
        if needsReload {
            // Run the follow-up separately, so callers waiting for this load aren't held up
            // by a folder that keeps changing.
            needsReload = false
            Task { await self.directoryDidChange() }
        }
        return true
    }

    /// The watched folder or archive changed. An archive's cached listing is dropped first.
    private func watchedItemDidChange(archive: URL?) async {
        if let archive { await catalog.invalidate(archive) }
        await directoryDidChange()
    }

    /// A change in the watched folder. Newer navigation supersedes an in-flight load, but a
    /// change of the folder being listed must not: in a busy folder each change would discard
    /// the running listing and nothing would ever be shown. It schedules one more load instead.
    func directoryDidChange() async {
        if let inFlightURL, inFlightURL == currentURL {
            needsReload = true
            return
        }
        await load()
    }

    /// Sorts `loadedItems` off the main actor and publishes them, unless something newer started.
    private func present(loadGeneration expectedLoad: Int) async {
        sortGeneration += 1
        let generation = sortGeneration
        let sorted = await Self.sort(loadedItems, by: settings.settings.sortOrder)
        guard generation == sortGeneration, expectedLoad == loadGeneration else { return }
        items = sorted
        listedURL = loadedURL
        archiveLocation = loadedLocation
        pruneSelection()
    }

    /// A different folder is shown: nothing from the previous one may stay selected, since
    /// actions on `selection` (e.g. Move to Trash) would hit invisible items.
    private func clearSelection() {
        selection = []
        pendingRename = nil
    }

    /// Drops selected entries that disappeared. Entries in the current folder are matched against
    /// `items` by canonical path (the loader may spell the folder differently, e.g. `/private/var`)
    /// and replaced by the item's URL; entries in its subfolders (inline-expanded) must still
    /// exist; entries anywhere else are dropped, since they can't be visible.
    /// In an archive, virtual paths don't exist on disk: entries in the current folder are matched
    /// by name, and entries below it are kept.
    private func pruneSelection() {
        guard !selection.isEmpty else { return }
        if archiveLocation != nil {
            pruneArchiveSelection()
            return
        }
        let directory = currentURL.resolvingSymlinksInPath().path
        let descendantPrefix = directory.hasSuffix("/") ? directory : directory + "/"
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
            guard resolved.hasPrefix(descendantPrefix) else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        })
        if pruned != selection { selection = pruned }
    }

    private func pruneArchiveSelection() {
        let directory = currentURL.standardizedFileURL.path
        let descendantPrefix = directory.hasSuffix("/") ? directory : directory + "/"
        var byName: [String: URL] = [:]
        for item in items { byName[item.url.lastPathComponent] = item.url }
        let pruned = Set(selection.compactMap { url -> URL? in
            let path = url.standardizedFileURL.path
            if url.deletingLastPathComponent().standardizedFileURL.path == directory {
                return byName[url.lastPathComponent]
            }
            return path.hasPrefix(descendantPrefix) ? url : nil
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

    /// Device and inode of a folder (or archive file), to tell a recreated one from the one being watched.
    private struct FolderIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// Keeps an existing watcher for the same folder, so frequent reloads don't keep resetting
    /// its maximum-latency window. A folder deleted and recreated at the same path is a new
    /// vnode, so the old watcher is dead and must be replaced. An archive file is watched the
    /// same way (`O_EVTONLY` works on files): writes, and deletion or replacement by rename.
    private func startWatching(_ url: URL, isArchive: Bool) {
        let identity = FolderIdentity(path: url.path)
        if watcher != nil, watchedURL == url, let identity, identity == watchedIdentity { return }
        watcher?.cancel()
        watchedURL = url
        watchedIdentity = identity
        let archive = isArchive ? url : nil
        watcher = DirectoryWatcher(url: url) { [weak self] in
            Task { @MainActor in await self?.watchedItemDidChange(archive: archive) }
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

    /// Operations and undo post the folders they changed; reload when one is the current folder,
    /// without waiting for the watcher. Goes through `directoryDidChange()` to coalesce with a
    /// load in flight.
    private func observeFolderChanges() {
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: FileOperationCenter.foldersDidChange, object: operations, queue: nil
        ) { [weak self] note in
            let folders = note.userInfo?["folders"] as? [URL] ?? []
            Task { @MainActor in await self?.foldersDidChange(folders) }
        }
        foldersObservation = NotificationObservation(center: center, token: token)
    }

    private func foldersDidChange(_ folders: [URL]) async {
        guard folders.contains(where: { isCurrentDirectory($0) }) else { return }
        await directoryDidChange()
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

    /// A listing: the items, and for an archive the inner folder they come from.
    private struct ListedItems: Sendable {
        let items: [FileItem]
        let inner: String?
    }

    private enum ListingError: Error {
        case folder(DirectoryLoadError)
        case archive(ArchiveError)
    }

    /// Lists `location` from the catalog. An inner folder missing from the index falls back to
    /// its deepest existing ancestor ("" always exists); the result says which folder was listed.
    /// Off the main actor: the walk is a dictionary lookup per component, but the index can be large.
    @concurrent
    private static func listArchive(
        _ location: ArchiveLocation, catalog: ArchiveCatalog, includeHidden: Bool
    ) async throws(ArchiveError) -> ListedItems {
        let index = try await catalog.index(of: location.archive)
        var components = location.inner.split(separator: "/").map(String.init)
        while !components.isEmpty, !index.containsFolder(components.joined(separator: "/")) {
            components.removeLast()
        }
        let inner = components.joined(separator: "/")
        let items = try await catalog.items(in: inner, of: location.archive, includeHidden: includeHidden)
        return ListedItems(items: items, inner: inner)
    }

    private static func loadError(_ error: ArchiveError, archive: URL) -> DirectoryLoadError {
        switch error {
        case .passwordRequired: .archivePasswordRequired(archive)
        case .incorrectPassword: .archiveIncorrectPassword(archive)
        case .unsupported(let message), .unreadable(let message): .archiveUnreadable(archive, message)
        case .cancelled: .archiveUnreadable(archive, String(localized: "The listing was cancelled."))
        }
    }

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
