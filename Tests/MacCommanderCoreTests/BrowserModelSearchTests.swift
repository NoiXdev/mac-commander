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
/// every query.
private final class FakeSearchEngine: FileSearchEngine, @unchecked Sendable {
    // @unchecked: `recorded` is only touched under `lock`; `script` is immutable.
    private let lock = NSLock()
    private var recorded: [SearchQuery] = []
    private let script: @Sendable (SearchQuery, Int) async -> [SearchUpdate]

    init(script: @escaping @Sendable (SearchQuery, Int) async -> [SearchUpdate]) {
        self.script = script
    }

    var queries: [SearchQuery] { lock.withLock { recorded } }

    func search(_ query: SearchQuery, includeHidden: Bool) -> AsyncStream<SearchUpdate> {
        let index = lock.withLock {
            recorded.append(query)
            return recorded.count - 1
        }
        let script = script
        return AsyncStream { continuation in
            let task = Task {
                for update in await script(query, index) { continuation.yield(update) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
@Suite struct BrowserModelSearchTests {
    private func makeStore() -> ViewSettingsStore {
        ViewSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
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
