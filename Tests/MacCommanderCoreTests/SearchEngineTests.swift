import Foundation
import Synchronization
import Testing

@testable import MacCommanderCore

/// Runs a search to completion and returns every update.
private func collect(_ stream: AsyncStream<SearchUpdate>) async -> [SearchUpdate] {
    var updates: [SearchUpdate] = []
    for await update in stream { updates.append(update) }
    return updates
}

/// The items of the last `.results` update, by file name.
private func lastNames(_ updates: [SearchUpdate]) -> [String] {
    for update in updates.reversed() {
        if case .results(let items, _) = update { return items.map(\.url.lastPathComponent).sorted() }
    }
    return []
}

/// An engine that records its queries and replays fixed updates.
private final class FakeEngine: FileSearchEngine, Sendable {
    let updates: [SearchUpdate]
    let calls = Mutex<[SearchQuery]>([])

    init(_ updates: [SearchUpdate]) { self.updates = updates }

    func search(_ query: SearchQuery, includeHidden: Bool) -> AsyncStream<SearchUpdate> {
        calls.withLock { $0.append(query) }
        let updates = updates
        return AsyncStream { continuation in
            for update in updates { continuation.yield(update) }
            continuation.finish()
        }
    }

    var callCount: Int { calls.withLock { $0.count } }
}

struct SearchEngineTests {
    @Test func enumerationFindsNestedMatches() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("a/Report.txt")
        try tmp.file("a/b/report-2.md")
        try tmp.file("a/b/other.txt")
        try tmp.file("pkg.app/Contents/report.txt")
        let updates = await collect(
            EnumerationSearch().search(SearchQuery(text: "report", scope: .folder(tmp.url)), includeHidden: false))
        #expect(lastNames(updates) == ["Report.txt", "report-2.md"])
        #expect(updates.last == .finished)
    }

    @Test func enumerationHonorsHidden() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file(".report")
        let query = SearchQuery(text: "report", scope: .folder(tmp.url))
        #expect(lastNames(await collect(EnumerationSearch().search(query, includeHidden: false))) == [])
        #expect(lastNames(await collect(EnumerationSearch().search(query, includeHidden: true))) == [".report"])
    }

    @Test func enumerationCancelsAndCaps() async throws {
        let tmp = try TemporaryDirectory()
        for i in 0..<20 { try tmp.file("match-\(i).txt") }
        let query = SearchQuery(text: "match", scope: .folder(tmp.url))
        let updates = await collect(EnumerationSearch(limit: 5).search(query, includeHidden: false))
        #expect(updates.last == .finished)
        guard case .results(let items, let truncated) = updates.dropLast().last else {
            Issue.record("no results before .finished")
            return
        }
        #expect(items.count == 5)
        #expect(truncated)

        // Many entries and no throttling, so the first update arrives long before the walk ends.
        for i in 0..<2_000 { FileManager.default.createFile(atPath: tmp.url.path + "/match-x\(i)", contents: nil) }
        let start = ContinuousClock.now
        for await _ in EnumerationSearch(limit: 10_000, interval: .zero).search(query, includeHidden: false) {
            break
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func enumerationThrottlesToOneFinalUpdate() async throws {
        let tmp = try TemporaryDirectory()
        for i in 0..<10 { try tmp.file("match-\(i).txt") }
        let updates = await collect(
            EnumerationSearch(limit: 10_000, interval: .seconds(3600))
                .search(SearchQuery(text: "match", scope: .folder(tmp.url)), includeHidden: false))
        #expect(updates.count == 2)
        #expect(lastNames(updates).count == 10)
    }

    @Test func enumerationEmptyAndTag() async throws {
        let tmp = try TemporaryDirectory()
        let none = await collect(
            EnumerationSearch().search(SearchQuery(text: "nothing", scope: .folder(tmp.url)), includeHidden: false))
        #expect(none == [.results([], truncated: false), .finished])
        let tag = await collect(EnumerationSearch().search(SearchQuery(text: "", scope: .tag("Red")), includeHidden: false))
        #expect(tag == [.finished])
    }

    @Test func compositeFallsBackWhenSpotlightEmpty() async throws {
        let tmp = try TemporaryDirectory()
        let item = try FileItem.load(try tmp.file("report.txt"))
        let spotlight = FakeEngine([.results([], truncated: false), .finished])
        let enumeration = FakeEngine([.results([item], truncated: false), .finished])
        let composite = CompositeSearch(spotlight: spotlight, enumeration: enumeration, isLocal: { _ in true })
        let updates = await collect(composite.search(SearchQuery(text: "report", scope: .folder(tmp.url)), includeHidden: false))
        #expect(spotlight.callCount == 1)
        #expect(enumeration.callCount == 1)
        #expect(updates == [.results([item], truncated: false), .finished])
    }

    @Test func compositeKeepsSpotlightResults() async throws {
        let tmp = try TemporaryDirectory()
        let item = try FileItem.load(try tmp.file("report.txt"))
        let spotlight = FakeEngine([.results([item], truncated: false), .finished])
        let enumeration = FakeEngine([.finished])
        let composite = CompositeSearch(spotlight: spotlight, enumeration: enumeration, isLocal: { _ in true })
        let updates = await collect(composite.search(SearchQuery(text: "report", scope: .folder(tmp.url)), includeHidden: false))
        #expect(enumeration.callCount == 0)
        #expect(updates == [.results([item], truncated: false), .finished])
    }

    @Test func compositeUsesEnumerationOnNetwork() async throws {
        let tmp = try TemporaryDirectory()
        let spotlight = FakeEngine([.finished])
        let enumeration = FakeEngine([.results([], truncated: false), .finished])
        let composite = CompositeSearch(spotlight: spotlight, enumeration: enumeration, isLocal: { _ in false })
        let updates = await collect(composite.search(SearchQuery(text: "x", scope: .folder(tmp.url)), includeHidden: false))
        #expect(spotlight.callCount == 0)
        #expect(enumeration.callCount == 1)
        #expect(updates == [.results([], truncated: false), .finished])
    }

    @Test func compositeTagUsesSpotlight() async {
        let spotlight = FakeEngine([.results([], truncated: false), .finished])
        let enumeration = FakeEngine([.finished])
        let composite = CompositeSearch(spotlight: spotlight, enumeration: enumeration, isLocal: { _ in true })
        let updates = await collect(composite.search(SearchQuery(text: "", scope: .tag("Red")), includeHidden: false))
        #expect(spotlight.calls.withLock { $0 } == [SearchQuery(text: "", scope: .tag("Red"))])
        #expect(enumeration.callCount == 0)
        #expect(updates == [.results([], truncated: false), .finished])
    }
}
