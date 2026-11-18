import Foundation
import Testing

@testable import MacCommanderCore

/// Polls until `condition` holds or the deadline passes.
@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
}

/// Suspends callers of `wait()` until `open()`.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Yields the updates `script` returns for each search (with the search's index, counting from 0) and records
/// every query. `init(streaming:)` yields them one by one instead, so a search can pause between updates.
private final class FakeSearchEngine: FileSearchEngine, @unchecked Sendable {
    // @unchecked: `recorded` is only touched under `lock`; `stream` is immutable.
    private let lock = NSLock()
    private var recorded: [SearchQuery] = []
    private let stream: @Sendable (SearchQuery, Int, AsyncStream<SearchUpdate>.Continuation) async -> Void

    init(streaming: @escaping @Sendable (SearchQuery, Int, AsyncStream<SearchUpdate>.Continuation) async -> Void) {
        stream = streaming
    }

    convenience init(script: @escaping @Sendable (SearchQuery, Int) async -> [SearchUpdate]) {
        self.init { query, index, continuation in
            for update in await script(query, index) { continuation.yield(update) }
        }
    }

    var queries: [SearchQuery] { lock.withLock { recorded } }

    func search(_ query: SearchQuery, includeHidden: Bool) -> AsyncStream<SearchUpdate> {
        let index = lock.withLock {
            recorded.append(query)
            return recorded.count - 1
        }
        let stream = stream
        return AsyncStream { continuation in
            let task = Task {
                await stream(query, index, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Which path checks wait for `gate`: `info` of `infoPath`, `archiveLocation` of `archivePath`.
@MainActor
private final class QueryGates {
    var infoPath: String?
    var archivePath: String?
    /// How many checks reached the gate.
    var reached = 0
    let gate = Gate()

    func pass(_ url: URL, gated path: String?) async {
        guard let path, url.standardizedFileURL.path == path else { return }
        reached += 1
        await gate.wait()
    }
}

/// The real path queries, except that the checks chosen in `gates` wait (like a stat on a slow server).
private struct GatedQueries: PathQueriesProvider {
    let gates: QueryGates

    func info(_ url: URL) async -> PathInfo {
        await gates.pass(url, gated: await gates.infoPath)
        return await PathQueries.info(url)
    }
    func archiveLocation(_ url: URL) async -> ArchiveLocation? {
        await gates.pass(url, gated: await gates.archivePath)
        return await PathQueries.archiveLocation(url)
    }
    func nearestExistingFolder(_ url: URL) async -> URL { await PathQueries.nearestExistingFolder(url) }
    func canonicalPath(_ url: URL) async -> String { await PathQueries.canonicalPath(url) }
    func resolvingSymlink(_ url: URL) async -> URL { await PathQueries.resolvingSymlink(url) }
    func entryExists(_ url: URL) async -> Bool { await PathQueries.entryExists(url) }
}

@MainActor
@Suite struct BrowserModelSearchTests {
    private let defaults = TemporaryDefaults()

    private func makeStore() -> ViewSettingsStore {
        ViewSettingsStore(defaults: defaults.make())
    }

    private func names(_ model: BrowserModel) -> [String] {
        model.items.map(\.url.lastPathComponent)
    }

    private func makeModel(start: URL, engine: FakeSearchEngine) -> BrowserModel {
        BrowserModel(start: start, settings: makeStore(), searchEngine: engine)
    }

    /// A folder with `top.txt`, and `sub/` holding the given result files.
    private func makeTree(results: [String]) throws -> (dir: TemporaryDirectory, items: [FileItem]) {
        let dir = try TemporaryDirectory()
        try dir.file("top.txt")
        let items = try results.map { try FileItem.load(try dir.file("sub/\($0)")) }
        return (dir, items)
    }

    @Test func startSearchShowsResults() async throws {
        let (dir, found) = try makeTree(results: ["c.txt", "a.txt", "b.txt"])
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()

        await model.startSearch("txt")

        #expect(await waitUntil { names(model) == ["a.txt", "b.txt", "c.txt"] })
        #expect(model.isSearching)
        #expect(model.searchIsRunning == false)
        #expect(model.searchTruncated == false)
        #expect(model.listedURL.map { samePath($0, dir.url) } == true)
        #expect(engine.queries == [SearchQuery(text: "txt", scope: .folder(model.currentURL))])
    }

    @Test func truncatedFlagIsPublished() async throws {
        let (dir, found) = try makeTree(results: ["a.txt"])
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: true), .finished] }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()

        await model.startSearch("a")

        #expect(await waitUntil { model.searchTruncated })
    }

    @Test func emptyTextEndsSearch() async throws {
        let (dir, found) = try makeTree(results: ["a.txt"])
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()
        await model.startSearch("a")
        #expect(await waitUntil { names(model) == ["a.txt"] })

        await model.startSearch("  ")

        #expect(model.isSearching == false)
        #expect(await waitUntil { names(model) == ["sub", "top.txt"] })
        // Ending a search that isn't running changes nothing.
        model.endSearch()
        #expect(model.isSearching == false)
    }

    @Test func staleResultsDropped() async throws {
        let (dir, found) = try makeTree(results: ["a1.txt", "b1.txt"])
        let gate = Gate()
        let engine = FakeSearchEngine { query, index in
            if index == 0 || index == 2 { await gate.wait() }
            return [.results(found.filter { $0.name.hasPrefix(query.text) }, truncated: false), .finished]
        }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()

        let first = Task { await model.startSearch("a") }
        #expect(await waitUntil { engine.queries.count == 1 })
        await model.startSearch("b")
        #expect(await waitUntil { names(model) == ["b1.txt"] })
        gate.open()
        await first.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(names(model) == ["b1.txt"])

        // A navigation mid-search: nothing lands in the new folder.
        let gate2 = Gate()
        let engine2 = FakeSearchEngine { _, _ in
            await gate2.wait()
            return [.results(found, truncated: false), .finished]
        }
        let other = try dir.folder("other")
        try dir.file("other/inside.txt")
        let model2 = makeModel(start: dir.url, engine: engine2)
        await model2.reload()
        let search = Task { await model2.startSearch("a") }
        #expect(await waitUntil { engine2.queries.count == 1 })
        await model2.navigate(to: other)
        gate2.open()
        await search.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(model2.isSearching == false)
        #expect(samePath(model2.currentURL, other))
        #expect(names(model2) == ["inside.txt"])
    }

    @Test func staleUpdatesDroppedWithoutCancellation() async throws {
        let (dir, found) = try makeTree(results: ["a1.txt", "a2.txt", "b1.txt"])
        let gateA = Gate()
        // Search 0 keeps going whatever happens (it never checks cancellation).
        let engine = FakeSearchEngine { query, index, continuation in
            let matching = found.filter { $0.name.hasPrefix(query.text) }
            if index == 0 {
                continuation.yield(.results([matching[0]], truncated: false))
                await gateA.wait()
            }
            continuation.yield(.results(matching, truncated: false))
            continuation.yield(.finished)
        }
        let gates = QueryGates()
        let model = BrowserModel(
            start: dir.url, settings: makeStore(), searchEngine: engine, pathQueries: GatedQueries(gates: gates))
        await model.reload()
        let first = Task { await model.startSearch("a") }
        #expect(await waitUntil { names(model) == ["a1.txt"] })

        // "b" is typed: its request is current while its folder check hangs, and search 0's task still runs
        // (it is only cancelled once "b" starts). Search 0's next snapshot must not land.
        gates.archivePath = dir.url.standardizedFileURL.path
        let second = Task { await model.startSearch("b") }
        #expect(await waitUntil { gates.reached == 1 })
        gateA.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(names(model) == ["a1.txt"])

        gates.gate.open()
        await second.value
        #expect(await waitUntil { names(model) == ["b1.txt"] })
        await first.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(names(model) == ["b1.txt"])
    }

    @Test func backEndsSearchWithoutMovingHistory() async throws {
        let (dir, found) = try makeTree(results: ["a.txt"])
        let a = try dir.folder("A")
        let b = try dir.folder("B")
        try dir.file("B/inB.txt")
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let model = makeModel(start: a, engine: engine)
        await model.reload()
        await model.navigate(to: b)
        await model.startSearch("a")
        #expect(await waitUntil { names(model) == ["a.txt"] })

        await model.goBack()

        #expect(samePath(model.currentURL, b))
        #expect(model.isSearching == false)
        #expect(await waitUntil { names(model) == ["inB.txt"] })

        await model.goBack()
        #expect(samePath(model.currentURL, a))
    }

    @Test func watcherDoesNotClobberResults() async throws {
        let (dir, found) = try makeTree(results: ["a.txt"])
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()
        await model.startSearch("a")
        #expect(await waitUntil { names(model) == ["a.txt"] })

        try dir.file("new.txt")
        try await Task.sleep(for: .milliseconds(800))

        #expect(names(model) == ["a.txt"])
        #expect(model.isSearching)
    }

    @Test func foldersChangeRerunsSearch() async throws {
        let (dir, found) = try makeTree(results: ["a.txt"])
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()
        await model.startSearch("a")
        #expect(await waitUntil { names(model) == ["a.txt"] })

        // A tag edit on a result announces its parent folder.
        model.operations.announceChanged(folders: [found[0].url.deletingLastPathComponent()])

        #expect(await waitUntil { engine.queries.count == 2 })
        #expect(engine.queries[1] == engine.queries[0])
        #expect(names(model) == ["a.txt"])
        #expect(model.isSearching)
    }

    @Test func tagScopeUsesTagQuery() async throws {
        let (dir, found) = try makeTree(results: ["red.txt"])
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()

        await model.showTag("Red")

        #expect(engine.queries.map(\.scope) == [.tag("Red")])
        #expect(model.search?.scope == .tag("Red"))
        #expect(await waitUntil { names(model) == ["red.txt"] })
    }

    @Test func noSearchInArchive() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(["a.txt": "a"], format: "zip", in: temp, name: "a.zip")
        let engine = FakeSearchEngine { _, _ in [.results([], truncated: false), .finished] }
        let model = makeModel(start: temp.url, engine: engine)
        await model.reload()
        await model.navigate(to: zip)
        #expect(model.archiveLocation != nil)

        await model.startSearch("a")

        #expect(model.isSearching == false)
        #expect(engine.queries.isEmpty)
        #expect(names(model) == ["a.txt"])
    }

    @Test func searchSupersedesPendingNavigation() async throws {
        let (dir, found) = try makeTree(results: ["a.txt"])
        let b = try dir.folder("B")
        let gates = QueryGates()
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let model = BrowserModel(
            start: dir.url, settings: makeStore(), searchEngine: engine, pathQueries: GatedQueries(gates: gates))
        await model.reload()

        // Click B (its check hangs), then type: the search covers the folder shown, and B never lands under it.
        gates.infoPath = b.standardizedFileURL.path
        let navigation = Task { await model.navigate(to: b) }
        #expect(await waitUntil { gates.reached == 1 })
        await model.startSearch("a")
        gates.gate.open()

        #expect(await navigation.value == .superseded)
        #expect(samePath(model.currentURL, dir.url))
        #expect(model.isSearching)
        #expect(engine.queries == [SearchQuery(text: "a", scope: .folder(model.currentURL))])
        #expect(names(model) == ["a.txt"])
    }

    @Test func clearingDropsSearchStillCheckingFolder() async throws {
        let (dir, found) = try makeTree(results: ["a.txt"])
        let gates = QueryGates()
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let model = BrowserModel(
            start: dir.url, settings: makeStore(), searchEngine: engine, pathQueries: GatedQueries(gates: gates))
        await model.reload()
        gates.archivePath = dir.url.standardizedFileURL.path

        // Cleared (the field calls `endSearch()`) while the archive check hangs.
        let search = Task { await model.startSearch("a") }
        #expect(await waitUntil { gates.reached == 1 })
        model.endSearch()
        // Cancelled (the field's debounce task is replaced) while the check hangs.
        let cancelled = Task { await model.startSearch("a") }
        #expect(await waitUntil { gates.reached == 2 })
        cancelled.cancel()
        gates.gate.open()
        await search.value
        await cancelled.value

        #expect(model.isSearching == false)
        #expect(engine.queries.isEmpty)
        #expect(names(model) == ["sub", "top.txt"])
    }

    @Test func rerunKeepsResultsUntilCaughtUp() async throws {
        let (dir, found) = try makeTree(results: ["a.txt", "b.txt", "c.txt"])
        let gate = Gate()
        let engine = FakeSearchEngine { _, index, continuation in
            switch index {
            case 1:
                // A re-run's first, partial snapshot; the rest after the gate.
                continuation.yield(.results([found[0]], truncated: false))
                await gate.wait()
                continuation.yield(.results(found, truncated: false))
            case 2:
                // A re-run that ends with fewer results: they are shown when it finishes.
                continuation.yield(.results([found[0]], truncated: false))
            default:
                continuation.yield(.results(found, truncated: true))
            }
            continuation.yield(.finished)
        }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()
        await model.startSearch("txt")
        #expect(await waitUntil { names(model) == ["a.txt", "b.txt", "c.txt"] && !model.searchIsRunning })
        #expect(model.searchTruncated)
        model.selection = [found[2].url]
        let parent = found[0].url.deletingLastPathComponent()

        model.operations.announceChanged(folders: [parent])
        #expect(await waitUntil { engine.queries.count == 2 })
        try await Task.sleep(for: .milliseconds(100))

        #expect(names(model) == ["a.txt", "b.txt", "c.txt"])
        #expect(model.selection == [found[2].url])
        #expect(model.searchTruncated)
        #expect(model.searchIsRunning)

        gate.open()
        #expect(await waitUntil { !model.searchIsRunning })
        #expect(names(model) == ["a.txt", "b.txt", "c.txt"])
        #expect(model.selection == [found[2].url])
        #expect(model.searchTruncated == false)

        model.operations.announceChanged(folders: [parent])
        #expect(await waitUntil { names(model) == ["a.txt"] && !model.searchIsRunning })
        #expect(model.selection.isEmpty)
    }

    @Test func vanishedResultDroppedBeforeRerunYields() async throws {
        let (dir, found) = try makeTree(results: ["a.txt", "b.txt"])
        let gate = Gate()
        let engine = FakeSearchEngine { _, index in
            // The re-run hangs (a slow network walk) and would still list the deleted file.
            if index > 0 { await gate.wait() }
            return [.results(found, truncated: false), .finished]
        }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()
        await model.startSearch("txt")
        #expect(await waitUntil { names(model) == ["a.txt", "b.txt"] && !model.searchIsRunning })
        model.selection = [found[0].url]

        try FileManager.default.removeItem(at: found[0].url)
        model.operations.announceChanged(folders: [found[0].url.deletingLastPathComponent()])

        #expect(await waitUntil { names(model) == ["b.txt"] })
        #expect(engine.queries.count == 2)
        #expect(model.searchIsRunning)
        #expect(model.selection.isEmpty)
        gate.open()
    }

    @Test func renamedResultShowsNewNameAtOnce() async throws {
        let (dir, found) = try makeTree(results: ["a.txt", "b.txt"])
        let gate = Gate()
        let engine = FakeSearchEngine { _, index in
            if index > 0 { await gate.wait() }
            return [.results(found, truncated: false), .finished]
        }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()
        await model.startSearch("txt")
        #expect(await waitUntil { names(model) == ["a.txt", "b.txt"] && !model.searchIsRunning })

        _ = try await model.rename(found[0].url, to: "c.txt")

        #expect(names(model) == ["b.txt", "c.txt"])
        #expect(engine.queries.count == 2)
        gate.open()
    }

    @Test func createInResultFolderRerunsSearch() async throws {
        let dir = try TemporaryDirectory()
        let sub = try dir.folder("sub")
        let found = [try FileItem.load(sub)]
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let model = makeModel(start: dir.url, engine: engine)
        await model.reload()
        await model.startSearch("sub")
        #expect(await waitUntil { names(model) == ["sub"] })

        let created = try await model.createFolder(in: found[0].url)

        #expect(await waitUntil { engine.queries.count == 2 })
        #expect(model.pendingRename == created)
        #expect(model.selection == [created])
        #expect(names(model) == ["sub"])
    }

    @Test func sortChangeResortsResults() async throws {
        let (dir, found) = try makeTree(results: ["a.txt", "b.txt"])
        let engine = FakeSearchEngine { _, _ in [.results(found, truncated: false), .finished] }
        let store = makeStore()
        let model = BrowserModel(start: dir.url, settings: store, searchEngine: engine)
        await model.reload()
        await model.startSearch("txt")
        #expect(await waitUntil { names(model) == ["a.txt", "b.txt"] })

        store.settings.sortOrder.ascending = false

        #expect(await waitUntil { names(model) == ["b.txt", "a.txt"] })
    }
}
