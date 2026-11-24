import AppKit
import Foundation
import Observation

/// What a navigation request did.
public enum NavigationResult: Sendable, Equatable {
    /// Navigated, or nothing to do (already there, or a file that isn't browsable).
    case done
    /// Nothing exists at the requested path.
    case missing
    /// A newer navigation request was made while this one checked its target; it was dropped.
    case superseded
}

/// A saved network share that dropped while one of its folders was shown.
public struct DisconnectedShare: Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// Where the share was mounted when it dropped; a reconnect may mount it elsewhere (`Media-1`).
    public let mountPoint: URL

    public init(id: UUID, name: String, mountPoint: URL) {
        self.id = id
        self.name = name
        self.mountPoint = mountPoint
    }
}

/// What `BrowserModel.shareResolver` reports for a path on a saved share. `isConnected`: the manager reports the
/// share connected at `mountPoint`. `isKnownDisconnected`: the manager knows the share's server is gone (unreachable),
/// so any stat under it may hang; false otherwise (also while it is still being checked).
public typealias ShareLookup = (
    id: UUID, name: String, mountPoint: URL, isConnected: Bool, isKnownDisconnected: Bool
)

/// Per-window view model: the current folder, its sorted items, selection and navigation.
///
/// `init` does not touch the disk; the UI calls `reload()` once when the window appears. Nothing here
/// touches the file system on the main actor: any folder may be on a network volume, where a `stat` can
/// block until the server times out. Path checks go through `PathQueries` (off the main actor), and
/// every load re-checks after each await that it is still the newest one before changing state.
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
    /// Set together with `loadError = .shareDisconnected`: the share whose folder is shown but gone.
    public private(set) var disconnectedShare: DisconnectedShare?
    /// The saved network share containing a path, if any: a pure main-actor lookup without file-system
    /// access (the UI wires it to `ShareManager.mountPoint(containing:)`). `isConnected` is whether the
    /// manager reports the share connected at that mount point. A vanished folder on a share that isn't
    /// connected (or whose mount point is gone too) shows `.shareDisconnected` instead of falling back to an
    /// ancestor. A path on a share known to be disconnected (`isKnownDisconnected`) shows `.shareDisconnected`
    /// at once, without any file-system access: a `stat` on a dead mount can hang until the server times out.
    @ObservationIgnored public var shareResolver: (@MainActor (URL) -> ShareLookup?)?
    /// Called with the share's id whenever this window shows a share's Disconnected placeholder, so the app can
    /// re-check that share (the UI wires it to `ShareManager.recheck`, which coalesces).
    @ObservationIgnored public var shareDropped: (@MainActor (UUID) -> Void)?
    /// The last placeholder recovery (share id, navigation generation after it): until the next navigation,
    /// a connect of that share counts as the recovery (see `shareDidConnect`).
    @ObservationIgnored private var recovery: (id: UUID, navigation: Int)?
    public var selection: Set<URL> = []
    /// One-shot: set by `select` and `reveal` so the list scrolls the selection into view once it shows it, then
    /// sets it back to false. Cleared by every navigation request. Other selection changes leave the scroll alone.
    @ObservationIgnored public var scrollsSelectionIntoView = false
    /// Set after a create; the list starts inline editing for it, then sets it back to nil.
    public var pendingRename: URL?

    /// The search or tag view shown over the current folder, nil when the folder itself is shown (Ruling P6-1:
    /// an overlay, not a history entry). While set, `items` are its sorted results and `listedURL` stays the folder.
    public private(set) var search: SearchQuery?
    /// The shown search hasn't finished yet.
    public private(set) var searchIsRunning = false
    /// The shown search hit the result cap.
    public private(set) var searchTruncated = false
    public var isSearching: Bool { search != nil }

    /// The app-wide operation center: undo history and operation notifications.
    @ObservationIgnored public let operations: FileOperationCenter
    @ObservationIgnored private let settings: ViewSettingsStore
    @ObservationIgnored private let loader: DirectoryLoader
    @ObservationIgnored private let opener: @MainActor (URL) -> Void
    /// Starts an iCloud download before a not-yet-downloaded file is handed to `opener`.
    @ObservationIgnored private let downloader: @MainActor (URL) async -> Void
    @ObservationIgnored private let catalog: ArchiveCatalog
    @ObservationIgnored private let queries: any PathQueriesProvider
    /// `currentURL` with its symlinks resolved, computed off the main actor by the load that listed it.
    /// Lets the main actor match other spellings of the current folder (`/var` vs `/private/var`).
    @ObservationIgnored private var canonicalCurrent: (url: URL, path: String)?
    /// What the newest load found at `currentURL` (for an archive: at the archive file).
    @ObservationIgnored private var currentInfo: (url: URL, info: PathInfo)?
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
    /// Bumped per navigation request (navigate, back, forward): a navigation whose off-main path checks
    /// finish after a newer request was made is dropped, so the last click wins.
    @ObservationIgnored private var navigationGeneration = 0
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
    /// Removes the share-connected observer when the model goes away.
    @ObservationIgnored private var shareObservation: NotificationObservation?
    /// Test hook: runs after a listing finishes, before its result is checked for staleness.
    @ObservationIgnored var afterListingHook: (@MainActor (URL) async -> Void)?
    /// Test hook: the folder watcher's debounce and maximum latency, read when a watcher is created.
    @ObservationIgnored var watcherTiming: (debounce: Duration, maxLatency: Duration) =
        (.milliseconds(200), .seconds(1))
    @ObservationIgnored private let searchEngine: any FileSearchEngine
    /// Consumes the shown search's updates; cancelled when the search is replaced or ended.
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The newest snapshot of the shown search, unsorted.
    @ObservationIgnored private var searchResults: [FileItem] = []
    /// Bumped per search request (start, re-run, end): updates of an older search are dropped.
    @ObservationIgnored private var searchGeneration = 0
    /// The folder's sorted items when the search started, shown again at once when it ends (a reload follows).
    @ObservationIgnored private var itemsBeforeSearch: [FileItem] = []

    public convenience init(
        start: URL,
        settings: ViewSettingsStore,
        loader: DirectoryLoader = DirectoryLoader(),
        opener: @escaping @MainActor (URL) -> Void = { PathQueries.openWithDefaultApp($0) },
        operations: FileOperationCenter = FileOperationCenter(),
        catalog: ArchiveCatalog = .shared,
        searchEngine: any FileSearchEngine = CompositeSearch(),
        downloader: @escaping @MainActor (URL) async -> Void = { await PathQueries.startDownloading($0) }
    ) {
        self.init(
            start: start, settings: settings, loader: loader, opener: opener, operations: operations,
            catalog: catalog, searchEngine: searchEngine, downloader: downloader, pathQueries: LivePathQueries())
    }

    /// `pathQueries` is a test hook; the public initializer passes the real `PathQueries`.
    init(
        start: URL,
        settings: ViewSettingsStore,
        loader: DirectoryLoader = DirectoryLoader(),
        opener: @escaping @MainActor (URL) -> Void = { PathQueries.openWithDefaultApp($0) },
        operations: FileOperationCenter = FileOperationCenter(),
        catalog: ArchiveCatalog = .shared,
        searchEngine: any FileSearchEngine = CompositeSearch(),
        downloader: @escaping @MainActor (URL) async -> Void = { await PathQueries.startDownloading($0) },
        pathQueries: any PathQueriesProvider
    ) {
        history = NavigationHistory(start: start)
        self.settings = settings
        self.searchEngine = searchEngine
        self.loader = loader
        self.opener = opener
        self.downloader = downloader
        self.operations = operations
        self.catalog = catalog
        self.queries = pathQueries
        observedSettings = settings.settings
        observeSettings()
        observeUnmounts()
        observeFolderChanges()
        observeShareConnects()
    }

    deinit {
        // The unmount observer is removed by `NotificationObservation.deinit`.
        watcher?.cancel()
    }

    /// Whether the newest load found the current folder (or archive) on a network volume. Answered from
    /// that load's cached `PathInfo`, without touching the disk; false while unknown.
    public var isOnNetworkVolume: Bool {
        guard let currentInfo, currentInfo.url.standardizedFileURL.path == currentURL.standardizedFileURL.path
        else { return false }
        return !currentInfo.info.isLocalVolume
    }

    /// Refresh on focus: lists a network folder again (local folders rely on their watcher). Coalesces with a
    /// load of this folder already in flight instead of superseding it, so toggling focus on a slow share
    /// never discards the running listing.
    public func refreshOnFocus() async {
        guard isOnNetworkVolume else { return }
        await directoryDidChange()
    }

    // MARK: - Navigation

    /// Navigates to a folder. A symlink to a folder navigates to its target, because the loader
    /// can't list through a symlink. Also navigates into archives: a pure archive file
    /// (`ArchiveFormats.isArchive`; a symlink to one keeps its own path), and any virtual path
    /// inside an archive (Go to Folder `…/a.zip/img`). Other files and missing paths are ignored, except a
    /// path on a saved share that isn't connected: it is shown with the share's Disconnected placeholder (and
    /// its Reconnect), never reported `.missing`.
    /// Every public navigation takes its place in line when called: one whose off-main checks finish
    /// after a newer request was made is dropped (`.superseded`), so the last click wins.
    @discardableResult
    public func navigate(to requested: URL) async -> NavigationResult {
        endSearch()
        return await navigate(to: requested, anyBrowsable: false, openFallback: false, generation: beginNavigation())
    }

    /// A new window's preferred folder, known only after the window opened at a stand-in (home): replaces the
    /// start of the history instead of visiting it, so Back doesn't lead to the stand-in. Ignored (false) when
    /// `url` isn't a folder, or once anything was navigated: history entries exist, a search is shown, or a
    /// navigation request was made meanwhile. Checks `url` off the main actor, like `navigate`.
    @discardableResult
    public func replaceStart(with url: URL) async -> Bool {
        let historyAtStart = history
        let generation = navigationGeneration
        guard !historyAtStart.canGoBack, !historyAtStart.canGoForward, !isSearching else { return false }
        func untouched() -> Bool { generation == navigationGeneration && history == historyAtStart && !isSearching }
        guard await queries.info(url).isDirectory, untouched() else { return false }
        let target = await queries.resolvingSymlink(url)
        guard untouched() else { return false }
        history = NavigationHistory(start: target)
        clearSelection()
        await load()
        return true
    }

    /// Starts a navigation request; any request started earlier is superseded from now on.
    private func beginNavigation() -> Int {
        scrollsSelectionIntoView = false
        navigationGeneration += 1
        return navigationGeneration
    }

    /// "Browse Contents": navigates into any browsable file (pure archives and containers such as
    /// `.docx`). Unreadable files show a load error. Items inside an archive are ignored, since
    /// nested archives aren't browsable.
    public func browseContents(_ item: FileItem) async {
        let generation = beginNavigation()
        guard !item.isDirectory, let location = await queries.archiveLocation(item.url), location.inner.isEmpty,
            generation == navigationGeneration
        else { return }
        endSearch()
        await navigate(to: item.url, anyBrowsable: true, openFallback: false, generation: generation)
    }

    /// `anyBrowsable` skips the extension check for an archive file; `openFallback` makes an
    /// unreadable archive go to `opener` instead of showing an error.
    /// `generation` comes from `beginNavigation()` at the public entry point.
    @discardableResult
    private func navigate(
        to requested: URL, anyBrowsable: Bool, openFallback: Bool, generation: Int
    ) async -> NavigationResult {
        // A share known to be down: its placeholder, without statting the dead path.
        if let share = shareResolver?(requested), share.isKnownDisconnected {
            return await visitDisconnected(requested)
        }
        // Checked off the main actor. A newer navigation request made meanwhile wins.
        let start = currentURL
        let url: URL
        let info = await queries.info(requested)
        guard generation == navigationGeneration else { return .superseded }
        if info.isDirectory {
            url = await queries.resolvingSymlink(requested)
        } else if let location = await queries.archiveLocation(requested) {
            // The archive file itself needs an archive extension, unless it's browsed explicitly or
            // reached from inside the same archive (goUp, breadcrumbs).
            var isAccepted = !location.inner.isEmpty || anyBrowsable || ArchiveFormats.isArchive(requested)
            if !isAccepted {
                isAccepted = await queries.archiveLocation(start)?.archive == location.archive
            }
            guard generation == navigationGeneration else { return .superseded }
            guard isAccepted else { return .done }
            url = requested
        } else if !info.exists, let share = shareResolver?(requested), !share.isConnected {
            // Not there because its share isn't connected: `load()` shows the placeholder.
            return await visitDisconnected(requested)
        } else {
            return info.exists ? .done : .missing
        }
        guard generation == navigationGeneration else { return .superseded }
        // By path: a folder URL may or may not carry a trailing slash.
        guard url.standardizedFileURL.path != currentURL.standardizedFileURL.path else { return .done }
        pendingOpenFallback = openFallback ? url : nil
        history.visit(url)
        clearSelection()
        await load()
        return .done
    }

    /// Visits `url` on a share that isn't connected; `load()` shows the Disconnected placeholder there.
    private func visitDisconnected(_ url: URL) async -> NavigationResult {
        pendingOpenFallback = nil
        if url.standardizedFileURL.path != currentURL.standardizedFileURL.path {
            history.visit(url)
            clearSelection()
        }
        await load()
        return .done
    }

    /// While a search is shown, only ends it (Ruling P6-1): the search is no history entry.
    public func goBack() async {
        _ = beginNavigation()
        if isSearching {
            endSearch()
            return
        }
        guard history.goBack() != nil else { return }
        pendingOpenFallback = nil
        clearSelection()
        await load()
    }

    public func goForward() async {
        _ = beginNavigation()
        endSearch()
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
    /// The shown items decide (`archiveLocation` is published with them), so this needs no split.
    /// Navigating ends a shown search; opening a file leaves it.
    public func open(_ item: FileItem) async {
        let generation = beginNavigation()
        if archiveLocation != nil, !isSearching {
            if item.isDirectory {
                endSearch()
                await navigate(to: item.url, anyBrowsable: false, openFallback: false, generation: generation)
            }
        } else if item.isDirectory {
            endSearch()
            await navigate(to: item.url, anyBrowsable: false, openFallback: false, generation: generation)
        } else if !item.isPackage, await isPlainFolder(item.url) {
            guard generation == navigationGeneration else { return }
            endSearch()
            await navigate(to: item.url, anyBrowsable: false, openFallback: false, generation: generation)
        } else if ArchiveFormats.isArchive(item.url) {
            endSearch()
            await navigate(to: item.url, anyBrowsable: false, openFallback: true, generation: generation)
        } else {
            if item.cloudStatus == .notDownloaded { await downloader(item.url) }
            opener(item.url)
        }
    }

    /// Lists a subfolder for inline expansion, with the same sorting and filtering as `items`.
    /// Virtual paths inside an archive are listed from the archive catalog.
    public func children(of url: URL) async throws(DirectoryLoadError) -> [FileItem] {
        let current = settings.settings
        let raw: [FileItem]
        if let location = await queries.archiveLocation(url) {
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
        guard let location = await queries.archiveLocation(currentURL) else { return }
        await catalog.setPassword(password, for: location.archive)
        await load()
    }

    // MARK: - Search

    /// Searches the current folder and its subfolders for names containing `text`; empty or whitespace text
    /// ends the search instead. Does nothing inside an archive (Ruling P6-2). Returns when this search finished,
    /// was replaced by a newer one, or ended.
    /// Takes its place in line like a navigation: a navigation still checking its target is superseded, so it
    /// can't land under the search (the search covers the folder shown when it was typed). Dropped when a
    /// navigation, a newer search request (also `endSearch()`) or cancelling the calling task comes first.
    public func startSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            endSearch()
            return
        }
        guard archiveLocation == nil else { return }
        let navigation = beginNavigation()
        searchGeneration += 1
        let request = searchGeneration
        let folder = currentURL
        // The archive file may be the current folder before its listing is published.
        let inArchive = await queries.archiveLocation(folder) != nil
        guard !inArchive, !Task.isCancelled, navigation == navigationGeneration, request == searchGeneration
        else { return }
        await runSearch(SearchQuery(text: trimmed, scope: .folder(folder)), keepingResults: false).value
    }

    /// Shows every file on this computer tagged `name`, over the current folder. Inside an archive it first goes
    /// to the folder holding the archive, so the results aren't shown in read-only archive mode.
    /// Like `startSearch`, it supersedes a navigation still checking its target.
    public func showTag(_ name: String) async {
        if let archive = archiveLocation?.archive {
            await navigate(to: archive.deletingLastPathComponent())
            guard archiveLocation == nil else { return }
        }
        _ = beginNavigation()
        await runSearch(SearchQuery(text: "", scope: .tag(name)), keepingResults: false).value
    }

    /// Ends the shown search and shows the folder again: at once its items from before the search, then a fresh
    /// listing (`load()`, started in a Task so this stays synchronous for the UI and the navigation paths, whose
    /// own load supersedes it). When no search is shown it only drops a `startSearch` still checking its folder.
    public func endSearch() {
        searchGeneration += 1
        guard search != nil else { return }
        searchTask?.cancel()
        searchTask = nil
        search = nil
        searchIsRunning = false
        searchTruncated = false
        searchResults = []
        sortGeneration += 1
        items = itemsBeforeSearch
        itemsBeforeSearch = []
        pruneSelection()
        Task { await self.load() }
    }

    /// Starts `query`, replacing any search shown. `keepingResults`: a re-run of the shown search (after a
    /// change), which keeps its results, truncation flag and selection until the new search has as many results
    /// or finishes: engines send growing snapshots, and a partial first one must not replace the full list.
    /// `pruning`: shown results checked first (one blocking batch); the ones gone are dropped at once, so a
    /// trashed or moved result doesn't stay listed until a slow re-run catches up.
    private func runSearch(_ query: SearchQuery, keepingResults: Bool, pruning: [URL] = []) -> Task<Void, Never> {
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        if search == nil { itemsBeforeSearch = items }
        search = query
        searchIsRunning = true
        if !keepingResults {
            searchTruncated = false
            searchResults = []
            sortGeneration += 1
            items = []
            clearSelection()
        }
        let stream = searchEngine.search(query, includeHidden: settings.settings.showHiddenFiles)
        let task = Task { [weak self] in
            if !pruning.isEmpty {
                guard await self?.dropVanishedResults(pruning, generation: generation) == true else { return }
            }
            guard let shownCount = self.map({ keepingResults ? $0.searchResults.count : 0 }) else { return }
            // A re-run's snapshot held back until it catches up with the shown results (or the search finishes).
            var heldBack: (found: [FileItem], truncated: Bool)?
            var caughtUp = !keepingResults
            for await update in stream {
                guard let self, generation == self.searchGeneration else { return }
                switch update {
                case .results(let found, let truncated):
                    if !caughtUp, found.count < shownCount, !truncated {
                        heldBack = (found, truncated)
                        continue
                    }
                    caughtUp = true
                    heldBack = nil
                    self.searchResults = found
                    self.searchTruncated = truncated
                    await self.presentSearch(generation: generation)
                case .finished:
                    if let held = heldBack {
                        heldBack = nil
                        self.searchResults = held.found
                        self.searchTruncated = held.truncated
                        await self.presentSearch(generation: generation)
                        guard generation == self.searchGeneration else { return }
                    }
                    self.searchIsRunning = false
                }
            }
        }
        searchTask = task
        return task
    }

    /// Runs the shown search again (same query), keeping its results until the new ones arrive. Results whose
    /// parent is one of `changedFolders` are checked first, and dropped when gone.
    private func rerunSearch(changedFolders: [URL] = []) {
        guard let search else { return }
        let changed = Set(changedFolders.map { $0.standardizedFileURL.path })
        let candidates = searchResults.map(\.url).filter {
            changed.contains($0.deletingLastPathComponent().standardizedFileURL.path)
        }
        _ = runSearch(search, keepingResults: true, pruning: candidates)
    }

    /// Drops the results among `urls` that no longer exist (lstat; only "no such file" counts, so an
    /// unreachable share keeps its rows). False when a newer search request came first.
    private func dropVanishedResults(_ urls: [URL], generation: Int) async -> Bool {
        let gone = await PathQueries.run { () -> Set<String> in
            Set(urls.filter { url in
                var info = stat()
                return lstat(url.path, &info) != 0 && (errno == ENOENT || errno == ENOTDIR)
            }.map { $0.standardizedFileURL.path })
        }
        guard generation == searchGeneration else { return false }
        guard !gone.isEmpty else { return true }
        searchResults.removeAll { gone.contains($0.url.standardizedFileURL.path) }
        await presentSearch(generation: generation)
        return generation == searchGeneration
    }

    /// Sorts `searchResults` off the main actor and publishes them, unless something newer started.
    private func presentSearch(generation expected: Int) async {
        sortGeneration += 1
        let generation = sortGeneration
        let sorted = await Self.sort(searchResults, by: settings.settings.sortOrder)
        guard generation == sortGeneration, expected == searchGeneration, search != nil else { return }
        items = sorted
        pruneSelection()
    }

    /// Whether a change of `folders` may change the shown search's results: the searched folder, a folder
    /// inside it (a new match may be there) or containing it, or the folder of a shown result. A tag view re-runs on any change: a newly
    /// tagged file can be anywhere.
    private func searchIsAffected(by folders: [URL], query: SearchQuery) -> Bool {
        guard case .folder(let root) = query.scope else { return true }
        var roots = [root.standardizedFileURL.path]
        if root == currentURL { roots = Array(currentDirectorySpellings()) }
        let prefixes = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let parents = Set(searchResults.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        return folders.contains { folder in
            let path = folder.standardizedFileURL.path
            if parents.contains(path) || roots.contains(path) || prefixes.contains(where: { path.hasPrefix($0) }) {
                return true
            }
            // A folder containing the searched one (it may have been moved or renamed).
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return roots.contains { $0.hasPrefix(prefix) }
        }
    }

    // MARK: - File operations

    /// Throws `CocoaError(.fileWriteNoPermission)` inside an archive, which is read-only.
    public func createFolder(in directory: URL? = nil) async throws -> URL {
        let parent = directory ?? currentURL
        try await refuseWritesInArchive(parent)
        let historyAtStart = history
        let folderName = ItemCreator.newFolderName
        let created = try await Self.offMain { try ItemCreator.createFolder(in: parent, named: folderName) }
        operations.recordCreated(created, isFolder: true)
        return await didCreate(created, in: parent, historyAtStart: historyAtStart)
    }

    /// The name for new files (the app wires it to the preferences).
    @ObservationIgnored public var newFileName: @MainActor () -> String = { Preferences.builtInNewFileName }

    /// The Open With rules (the app wires it to the preferences).
    @ObservationIgnored public var openWithRules: @MainActor () -> OpenWithRules = { OpenWithRules() }

    /// Hands each URL to `opener`, in order, for files opened outside the panes' own navigation (for
    /// example archive entries extracted by the UI).
    public func openExternally(_ urls: [URL]) {
        for url in urls { opener(url) }
    }

    /// Throws `CocoaError(.fileWriteNoPermission)` inside an archive, which is read-only.
    public func createEmptyFile(in directory: URL? = nil) async throws -> URL {
        let parent = directory ?? currentURL
        try await refuseWritesInArchive(parent)
        let historyAtStart = history
        let fileName = newFileName()
        let created = try await Self.offMain { try ItemCreator.createEmptyFile(in: parent, named: fileName) }
        operations.recordCreated(created, isFolder: false)
        return await didCreate(created, in: parent, historyAtStart: historyAtStart)
    }

    /// Returns the URL as spelled in `items` when the item is in the current folder and no
    /// navigation happened meanwhile; otherwise the renamed URL as is. Inside an archive it throws
    /// `.underlying` with the `CocoaError(.fileWriteNoPermission)` text (the error type is fixed).
    public func rename(_ url: URL, to name: String) async throws(RenameError) -> URL {
        do {
            try await refuseWritesInArchive(url.deletingLastPathComponent())
        } catch {
            throw .underlying(error.localizedDescription)
        }
        let historyAtStart = history
        let renamed = try await Self.rename(url, to: name)
        operations.recordRename(from: url, to: renamed)
        if let selected = selection.first(where: { isSameItem($0, url) }) {
            selection.remove(selected)
            selection.insert(renamed)
        }
        if isSearching {
            // Shows the new name at once, then re-runs (a rename posts no folder change), which drops the
            // result if it no longer matches.
            let reloaded = await PathQueries.run { try? FileItem.load(renamed) }
            guard isSearching else { return renamed }
            let oldPath = url.standardizedFileURL.path
            if let reloaded, let index = searchResults.firstIndex(where: { $0.url.standardizedFileURL.path == oldPath }) {
                searchResults[index] = reloaded
            }
            rerunSearch()
            await presentSearch(generation: searchGeneration)
            return renamed
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

    /// For a just-created model: selects the items of `urls` that are in the current folder (others are
    /// ignored) and lists the folder; does nothing when none is in it. The selection is seeded first, so whichever
    /// listing lands last (this one, or a concurrent `reload()` that supersedes it) normalizes it to the items'
    /// spellings. Sets `scrollsSelectionIntoView`.
    public func select(_ urls: [URL]) async {
        let historyAtStart = history
        let inFolder = urls.filter { isCurrentDirectory($0.deletingLastPathComponent()) }
        guard !inFolder.isEmpty, !isSearching else { return }
        scrollsSelectionIntoView = true
        selection = Set(inFolder)
        guard await reloadIfStillShowing(currentURL, since: historyAtStart) else { return }
        selection = Set(inFolder.map { itemURL(matching: $0) })
    }

    /// Shows a real file or folder in the list: navigates to its parent folder (unless that is the current
    /// folder already) and selects it, spelled as in `items`, setting `scrollsSelectionIntoView`. Targets inside an
    /// archive and missing targets are ignored. Checks the target off the main actor, like `navigate`. Returns false
    /// when ignored (the UI beeps), true otherwise.
    @discardableResult
    public func reveal(_ url: URL) async -> Bool {
        let generation = beginNavigation()
        let target = url.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        // lstat: a broken symlink is still an item in the list. `split` of a real file is the file itself
        // (an archive with an empty inner path), so the parent tells whether the target is inside an archive.
        guard await queries.entryExists(target), await queries.archiveLocation(parent) == nil else { return false }
        let canonicalParent = await queries.canonicalPath(parent)
        // A newer navigation request wins; this one isn't "ignored", so no beep.
        guard generation == navigationGeneration else { return true }
        endSearch()
        if !isCurrentDirectory(parent, canonical: canonicalParent) {
            await navigate(to: parent, anyBrowsable: false, openFallback: false, generation: generation)
            guard isCurrentDirectory(parent, canonical: canonicalParent) else { return true }
        }
        // Navigating resolves a symlinked parent, so the target may need the resolved spelling to match.
        let selected = isCurrentDirectory(parent)
            ? target
            // With an explicit hint: the one-argument `appendingPathComponent` stats the result on the main actor.
            // Selection matches items by name, so the hint doesn't matter.
            : URL(fileURLWithPath: canonicalParent, isDirectory: true)
                .appendingPathComponent(target.lastPathComponent, isDirectory: false)
        scrollsSelectionIntoView = true
        await selectAfterOperation([selected])
        return true
    }

    /// Archives are read-only; the UI disables writes there, this is the model's own guard.
    private func refuseWritesInArchive(_ folder: URL) async throws(CocoaError) {
        if archiveLocation != nil { throw CocoaError(.fileWriteNoPermission) }
        if await queries.archiveLocation(folder) != nil {
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
        // The spinner shows from the first path check on: on an unresponsive server that check is
        // what hangs (off the main actor), until a newer load supersedes this one.
        isLoading = true
        // In flight from the start, so a change reported during the path checks coalesces into it.
        inFlightURL = currentURL

        // On a saved share known to be down: the placeholder at once. No stat, which could hang on the dead
        // mount (and keep the spinner up) until the server times out.
        if let share = shareResolver?(currentURL), share.isKnownDisconnected {
            return await showDisconnected(share, generation: generation)
        }

        // A folder needs no split. Otherwise split: a virtual path inside an archive doesn't exist on
        // disk. A vanished archive splits to nil and falls back like a vanished folder.
        var target = await resolveLoadTarget(currentURL)
        guard generation == loadGeneration else { return false }
        if target.location == nil, !target.info.exists {
            // On a saved share that dropped: keep the folder and history, show Disconnected. On a share that
            // is still connected, only a folder deleted on it: fall back as usual, unless its mount point is
            // gone too (one off-main check).
            if let share = shareResolver?(currentURL) {
                var dropped = !share.isConnected
                if !dropped {
                    let root = await queries.info(share.mountPoint)
                    guard generation == loadGeneration else { return false }
                    dropped = !root.isDirectory
                }
                if dropped { return await showDisconnected(share, generation: generation) }
            }
            let fallback = await queries.nearestExistingFolder(currentURL)
            guard generation == loadGeneration else { return false }
            history.replaceCurrent(with: fallback)
            clearSelection()
            target = await resolveLoadTarget(currentURL)
            guard generation == loadGeneration else { return false }
        }
        let location = target.location
        let url = currentURL
        let current = settings.settings
        currentInfo = (url, target.info)
        // Watch before listing, so a change during the listing still triggers a reload.
        // In an archive the archive file itself is watched.
        guard await startWatching(location?.archive ?? url, isArchive: location != nil, generation: generation)
        else { return false }
        inFlightURL = url
        // Resolved alongside the listing, so other spellings of this folder can be matched later
        // without touching the disk on the main actor.
        async let canonical = location == nil ? queries.canonicalPath(url) : url.standardizedFileURL.path

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
        let canonicalPath = await canonical
        await afterListingHook?(url)
        guard generation == loadGeneration else { return false }
        canonicalCurrent = (url, canonicalPath)

        // A failure may mean the folder or archive vanished meanwhile: then fall back again.
        var vanished = false
        switch result {
        case .failure(.folder(.notFound)): vanished = !(await queries.info(url).exists)
        case .failure(.archive): if let location { vanished = !(await queries.info(location.archive).exists) }
        default: break
        }
        guard generation == loadGeneration else { return false }
        if vanished { return await load() }

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
            disconnectedShare = nil
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
            disconnectedShare = nil
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

    /// The current folder is gone and on a saved share: nothing is listed, the watcher stops (the path is
    /// dead), and `currentURL` and the history stay as they are, so a reconnect can return to the folder.
    /// `currentInfo` is cleared, so refresh on focus doesn't stat the dead path again; a reload re-checks once.
    private func showDisconnected(_ share: ShareLookup, generation: Int) async -> Bool {
        watcher?.cancel()
        watcher = nil
        watchedURL = nil
        watchedIdentity = nil
        currentInfo = nil
        canonicalCurrent = nil
        pendingOpenFallback = nil
        clearSelection()
        loadedItems = []
        loadedURL = nil
        loadedLocation = nil
        disconnectedShare = DisconnectedShare(id: share.id, name: share.name, mountPoint: share.mountPoint)
        loadError = .shareDisconnected(name: share.name)
        // The share's status may be stale (for example still "connected"): let the app check it again.
        shareDropped?(share.id)
        await present(loadGeneration: generation)
        guard generation == loadGeneration else { return false }
        isLoading = false
        inFlightURL = nil
        // Changes reported while checking concern the dead path; no follow-up load.
        needsReload = false
        return true
    }

    /// The share mounted at `oldMountPoint` is back at `newMountPoint` (possibly another name, e.g.
    /// `/Volumes/Media-1`): moves the current folder and the back/forward entries below the old mount point
    /// to the new one, and lists the current folder again. Supersedes pending navigation.
    public func reconnected(oldMountPoint: URL, newMountPoint: URL) async {
        beginReconnect(oldMountPoint: oldMountPoint, newMountPoint: newMountPoint)
        await load()
    }

    /// The synchronous part of `reconnected`, done before any await so a concurrent `shareDidConnect` for
    /// the same connect sees its result.
    private func beginReconnect(oldMountPoint: URL, newMountPoint: URL) {
        _ = beginNavigation()
        endSearch()
        disconnectedShare = nil
        history.rewritePrefix(from: oldMountPoint, to: newMountPoint)
    }

    /// A share was connected (`ShareManager.didConnectNotification`, or the UI's connect flow). If this
    /// window shows that share's Disconnected placeholder, it returns to the same folder under the new
    /// mount point and returns true. Also true when this window already recovered from that share's
    /// placeholder for this connect (the notification and the UI's connect flow race; whichever comes
    /// first recovers) and nothing was navigated since. False otherwise: the caller navigates as usual.
    @discardableResult
    public func shareDidConnect(id: UUID, mountPoint: URL) async -> Bool {
        guard let disconnected = disconnectedShare else {
            guard let recovery else { return false }
            return recovery.id == id && recovery.navigation == navigationGeneration
        }
        guard disconnected.id == id, shareResolver?(mountPoint)?.id == id else { return false }
        beginReconnect(oldMountPoint: disconnected.mountPoint, newMountPoint: mountPoint)
        recovery = (id, navigationGeneration)
        await load()
        return true
    }

    /// By standardized path, without file-system access.
    private static func isPath(_ url: URL, within root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// The watched folder or archive changed. An archive's cached listing is dropped first.
    private func watchedItemDidChange(archive: URL?) async {
        if let archive { await catalog.invalidate(archive) }
        await directoryDidChange()
    }

    /// A change in the watched folder. Newer navigation supersedes an in-flight load, but a
    /// change of the folder being listed must not: in a busy folder each change would discard
    /// the running listing and nothing would ever be shown. It schedules one more load instead.
    /// Ignored while a search is shown (its results stay; `endSearch()` lists the folder again).
    func directoryDidChange() async {
        guard !isSearching else { return }
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
        // A shown search keeps its results; `endSearch()` lists the folder again.
        guard generation == sortGeneration, expectedLoad == loadGeneration, !isSearching else { return }
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
    /// `items` by name (under any spelling of the folder, e.g. `/var` or `/private/var`) and replaced by
    /// the item's URL; entries in its subfolders (inline-expanded) are kept without a check, since a stat
    /// per entry could hang on a network volume (acting on a vanished one fails with a readable error);
    /// entries anywhere else are dropped, since they can't be visible.
    /// In an archive, virtual paths don't exist on disk: entries in the current folder are matched
    /// by name, and entries below it are kept.
    private func pruneSelection() {
        guard !selection.isEmpty else { return }
        if isSearching {
            pruneSearchSelection()
            return
        }
        if archiveLocation != nil {
            pruneArchiveSelection()
            return
        }
        let directories = currentDirectorySpellings()
        let descendantPrefixes = directories.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var byName: [String: URL] = [:]
        for item in items { byName[item.url.lastPathComponent] = item.url }
        let pruned = Set(selection.compactMap { url -> URL? in
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            if directories.contains(parent) {
                return byName[url.lastPathComponent]
            }
            let path = url.standardizedFileURL.path
            return descendantPrefixes.contains(where: { path.hasPrefix($0) }) ? url : nil
        })
        if pruned != selection { selection = pruned }
    }

    /// While searching: keeps shown results and entries below a shown folder (inline-expanded).
    private func pruneSearchSelection() {
        let shown = Set(items.map { $0.url.standardizedFileURL.path })
        let pruned = selection.filter { url in
            var path = url.standardizedFileURL.path
            while path.count > 1 {
                if shown.contains(path) { return true }
                path = (path as NSString).deletingLastPathComponent
            }
            return false
        }
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
        if isSearching {
            // Into a result folder (creating in the hidden current folder is disabled): re-run the search, which
            // keeps that folder shown; the list expands it for the rename.
            rerunSearch()
            selection = [created]
            pendingRename = created
            return created
        }
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
    /// Never while a search is shown: `items` are its results, not the folder's listing.
    private func reloadIfStillShowing(_ directory: URL, since historyAtStart: NavigationHistory) async -> Bool {
        guard !isSearching, history == historyAtStart, isCurrentDirectory(directory) else { return false }
        guard await load() else { return false }
        return history == historyAtStart && isCurrentDirectory(directory)
    }

    /// For a URL in the current folder: the matching item's URL, or `url` if there is none.
    /// Compares names only, so large folders need no per-item symlink resolution.
    private func itemURL(matching url: URL) -> URL {
        let name = url.lastPathComponent
        return items.first { $0.url.lastPathComponent == name }?.url ?? url
    }

    /// Whether `url` is the current folder, by standardized path against the current folder's spellings
    /// (as navigated, and with symlinks resolved by its last load). No disk access: a caller that already
    /// resolved `url` off the main actor (`PathQueries.canonicalPath`) passes that as `canonical`.
    private func isCurrentDirectory(_ url: URL, canonical: String? = nil) -> Bool {
        let spellings = currentDirectorySpellings()
        if spellings.contains(url.standardizedFileURL.path) { return true }
        return canonical.map(spellings.contains) ?? false
    }

    /// The standardized paths that name the current folder: as navigated, and resolved when the last
    /// load resolved this same folder.
    private func currentDirectorySpellings() -> Set<String> {
        var spellings: Set<String> = [currentURL.standardizedFileURL.path]
        if let canonicalCurrent, canonicalCurrent.url == currentURL {
            let path = canonicalCurrent.path
            spellings.insert(path)
            // `/var`, `/tmp` and `/etc` are symlinks into `/private`; Foundation often spells them short
            // (`resolvingSymlinksInPath` strips the prefix), so accept both.
            if path.hasPrefix("/private/") { spellings.insert(String(path.dropFirst("/private".count))) }
        }
        return spellings
    }

    /// Two URLs for one item: the same standardized path, or the same name in the current folder
    /// under two of its spellings.
    private func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL.path == rhs.standardizedFileURL.path { return true }
        guard lhs.lastPathComponent == rhs.lastPathComponent else { return false }
        let spellings = currentDirectorySpellings()
        return spellings.contains(lhs.deletingLastPathComponent().standardizedFileURL.path)
            && spellings.contains(rhs.deletingLastPathComponent().standardizedFileURL.path)
    }

    /// Device and inode of a folder (or archive file), to tell a recreated one from the one being watched.
    private struct FolderIdentity: Equatable, Sendable {
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
    /// The `stat` and `open` run off the main actor. Returns false (and changes nothing) when a newer
    /// load started meanwhile.
    private func startWatching(_ url: URL, isArchive: Bool, generation: Int) async -> Bool {
        let watching = watcher != nil && watchedURL == url ? watchedIdentity : nil
        let archive = isArchive ? url : nil
        let setup = await Self.prepareWatcher(
            url, keepingIdentity: watching, timing: watcherTiming
        ) { [weak self] in
            Task { @MainActor in await self?.watchedItemDidChange(archive: archive) }
        }
        guard generation == loadGeneration else {
            setup.watcher?.cancel()
            return false
        }
        guard !setup.keepsCurrent else { return true }
        watcher?.cancel()
        watchedURL = url
        watchedIdentity = setup.identity
        watcher = setup.watcher
        return true
    }

    private struct WatcherSetup: Sendable {
        /// True when the existing watcher still watches the same vnode; `watcher` is then nil.
        let keepsCurrent: Bool
        let identity: FolderIdentity?
        let watcher: DirectoryWatcher?
    }

    /// On the blocking-I/O queue: the `stat` and `open` can hang on an unresponsive server.
    private static func prepareWatcher(
        _ url: URL, keepingIdentity watched: FolderIdentity?, timing: (debounce: Duration, maxLatency: Duration),
        onChange: @escaping @Sendable () -> Void
    ) async -> WatcherSetup {
        await PathQueries.run {
            let identity = FolderIdentity(path: url.path)
            if let identity, identity == watched {
                return WatcherSetup(keepsCurrent: true, identity: identity, watcher: nil)
            }
            return WatcherSetup(
                keepsCurrent: false, identity: identity, watcher: DirectoryWatcher(
                    url: url, debounce: timing.debounce, maxLatency: timing.maxLatency, onChange: onChange))
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

    /// Unrelated volumes are ignored. On a saved share, `load()` shows Disconnected instead.
    private func volumeDidUnmount(_ volume: URL?) async {
        if let volume {
            guard Self.isPath(currentURL, within: volume) else { return }
        }
        guard !isSearching else {
            // Its results are gone with the volume; ending the search lists (or falls back from) the folder.
            endSearch()
            return
        }
        await load()
    }

    /// A share that reconnects by itself (auto-reconnect) brings back a window showing its placeholder.
    private func observeShareConnects() {
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: ShareManager.didConnectNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let mountPoint = note.userInfo?["mountPoint"] as? URL,
                let id = note.userInfo?["shareID"] as? UUID
            else { return }
            Task { @MainActor in
                guard let self, self.disconnectedShare != nil else { return }
                await self.shareDidConnect(id: id, mountPoint: mountPoint)
            }
        }
        shareObservation = NotificationObservation(center: center, token: token)
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

    /// While a search is shown, a change that may touch its results re-runs it instead (tag edits, operations).
    private func foldersDidChange(_ folders: [URL]) async {
        if let search {
            if searchIsAffected(by: folders, query: search) { rerunSearch(changedFolders: folders) }
            return
        }
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
        if isSearching {
            // The folder is listed again when the search ends.
            if new.showHiddenFiles != old.showHiddenFiles {
                rerunSearch()
            } else if new.sortOrder != old.sortOrder {
                await presentSearch(generation: searchGeneration)
            }
        } else if new.showHiddenFiles != old.showHiddenFiles {
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
        case .cancelled: .archiveUnreadable(archive, L10n.string("archive.error.listingCancelled", "The listing was cancelled."))
        }
    }

    /// A folder (symlinks followed) that isn't a package, checked off the main actor.
    private func isPlainFolder(_ url: URL) async -> Bool {
        let info = await queries.info(url)
        return info.isDirectory && !info.isPackage
    }

    /// What a load lists: for a folder its `PathInfo`; otherwise also the archive location, if any.
    /// For an archive the info describes the archive file (whose volume decides refresh on focus).
    private func resolveLoadTarget(_ url: URL) async -> (info: PathInfo, location: ArchiveLocation?) {
        let info = await queries.info(url)
        guard !info.isDirectory, let location = await queries.archiveLocation(url) else { return (info, nil) }
        let archiveInfo = location.inner.isEmpty ? info : await queries.info(location.archive)
        return (archiveInfo, location)
    }

    @concurrent
    private static func sort(_ items: [FileItem], by order: FileSortOrder) async -> [FileItem] {
        order.sorted(items)
    }

    /// Creating and renaming may hit a network volume: on the blocking-I/O queue.
    private static func offMain(_ work: @escaping @Sendable () throws -> URL) async throws -> URL {
        try await PathQueries.run { () throws(any Error) -> URL in try work() }
    }

    private static func rename(_ url: URL, to name: String) async throws(RenameError) -> URL {
        try await PathQueries.run { () throws(RenameError) -> URL in try ItemRenamer.rename(url, to: name) }
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
