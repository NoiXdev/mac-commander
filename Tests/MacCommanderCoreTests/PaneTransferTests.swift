import Foundation
import Testing

@testable import MacCommanderCore

@MainActor
struct PaneTransferTests {
    private let defaults = TemporaryDefaults()
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    private func makeModel(_ url: URL) -> BrowserModel {
        BrowserModel(start: url, settings: ViewSettingsStore(defaults: defaults.make()))
    }

    private func makeLayout(start: URL) -> PaneLayout {
        PaneLayout(primary: makeModel(start)) { makeModel($0) }
    }

    private func dualLayout() async throws -> (TemporaryDirectory, PaneLayout, URL, URL) {
        let dir = try TemporaryDirectory()
        try dir.file("A/f1.txt")
        try dir.file("A/f2.txt")
        try dir.file("A/report.pdf")
        try dir.file("B/y.txt")
        let a = dir.url.appendingPathComponent("A")
        let b = dir.url.appendingPathComponent("B")
        let layout = makeLayout(start: a)
        layout.showDual()
        await layout.panes[1].navigate(to: b)
        return (dir, layout, a, b)
    }

    @Test func topLevelDropsDescendants() {
        let urls: Set<URL> = ["/a", "/a/b", "/a/b/c", "/d", "/ab"].reduce(into: []) {
            $0.insert(URL(fileURLWithPath: $1))
        }
        #expect(PaneTransfer.topLevel(urls).map(\.path) == ["/a", "/ab", "/d"])
    }

    @Test func parseDestinationExpandsHome() {
        #expect(PaneTransfer.parseDestination("~", home: home)?.path == "/Users/me")
        #expect(PaneTransfer.parseDestination(" ~/x/ ", home: home)?.path == "/Users/me/x")
        #expect(PaneTransfer.parseDestination("/tmp/../tmp", home: home)?.path == "/tmp")
    }

    @Test func parseDestinationRejectsRelative() {
        #expect(PaneTransfer.parseDestination("", home: home) == nil)
        #expect(PaneTransfer.parseDestination("x/y", home: home) == nil)
        #expect(PaneTransfer.parseDestination("~bob/x", home: home) == nil)
    }

    @Test func copyRequestUsesOtherPaneFolder() async throws {
        let (dir, layout, a, _) = try await dualLayout()
        defer { withExtendedLifetime(dir) {} }
        layout.active.selection = [a.appendingPathComponent("f2.txt"), a.appendingPathComponent("f1.txt")]
        let request = try #require(layout.transferRequest(move: false))
        #expect(request.kind == .copy)
        #expect(request.sources.map(\.lastPathComponent) == ["f1.txt", "f2.txt"])
        #expect(request.destination == layout.panes[1].currentURL)
        #expect(request.title == "Copy 2 items to:")
    }

    @Test func singleItemTitleNamesIt() async throws {
        let (dir, layout, a, _) = try await dualLayout()
        defer { withExtendedLifetime(dir) {} }
        layout.active.selection = [a.appendingPathComponent("report.pdf")]
        let request = try #require(layout.transferRequest(move: true))
        #expect(request.kind == .move)
        #expect(request.title == "Move “report.pdf” to:")
    }

    @Test func noRequestWhenSingleOrEmpty() async throws {
        let (dir, layout, a, _) = try await dualLayout()
        defer { withExtendedLifetime(dir) {} }
        layout.active.selection = []
        #expect(layout.transferRequest(move: false) == nil)

        let single = makeLayout(start: a)
        single.active.selection = [a.appendingPathComponent("f1.txt")]
        #expect(single.transferRequest(move: false) == nil)
    }

    @Test func noTargetWhenOtherPaneIsNotARealFolder() async throws {
        let (dir, layout, a, b) = try await dualLayout()
        defer { withExtendedLifetime(dir) {} }
        layout.active.selection = [a.appendingPathComponent("f1.txt")]

        await layout.panes[1].startSearch("y")
        #expect(layout.panes[1].isSearching)
        #expect(layout.transferRequest(move: false) == nil)
        layout.panes[1].endSearch()

        let zip = try ArchiveFixtures.makeArchive(["a.txt": "a"], format: "zip", in: dir, name: "a.zip")
        await layout.panes[1].navigate(to: zip)
        #expect(layout.panes[1].archiveLocation != nil)
        #expect(layout.transferRequest(move: false) == nil)
        _ = b
    }

    @Test func archiveSourceExtractsAndRefusesMove() async throws {
        let dir = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(
            ["a.txt": "a", "img/x.png": "x", "b.txt": "b"], format: "zip", in: dir, name: "a.zip")
        try dir.file("B/y.txt")
        let layout = makeLayout(start: dir.url)
        layout.showDual()
        await layout.panes[1].navigate(to: dir.url.appendingPathComponent("B"))
        let pane = layout.active
        await pane.navigate(to: zip)
        pane.selection = [zip.appendingPathComponent("a.txt"), zip.appendingPathComponent("img")]

        let request = try #require(layout.transferRequest(move: false))
        #expect(request.kind == .extract(archive: pane.archiveLocation!.archive))
        #expect(request.entries == ["a.txt", "img"])
        #expect(request.title == "Extract 2 items to:")
        #expect(layout.transferRequest(move: true) == nil)
    }

    @Test func requestTransferSetsPending() async throws {
        let (dir, layout, a, _) = try await dualLayout()
        defer { withExtendedLifetime(dir) {} }
        #expect(!layout.requestTransfer(move: false))
        #expect(layout.pendingTransfer == nil)
        layout.active.selection = [a.appendingPathComponent("f1.txt")]
        #expect(layout.requestTransfer(move: false))
        #expect(layout.pendingTransfer != nil)
    }
}
