import Foundation
import Testing

@testable import MacCommanderCore

@MainActor
struct PaneLayoutTests {
    private let defaults = TemporaryDefaults()

    private func makeModel(_ url: URL) -> BrowserModel {
        BrowserModel(start: url, settings: ViewSettingsStore(defaults: defaults.make()))
    }

    private func makeLayout(start: URL) -> PaneLayout {
        PaneLayout(primary: makeModel(start)) { makeModel($0) }
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    private func folders() throws -> (TemporaryDirectory, URL, URL) {
        let dir = try TemporaryDirectory()
        try dir.file("A/x.txt")
        try dir.file("B/y.txt")
        return (dir, dir.url.appendingPathComponent("A"), dir.url.appendingPathComponent("B"))
    }

    @Test func startsSingleWithPrimaryActive() throws {
        let (dir, a, _) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let primary = makeModel(a)
        let layout = PaneLayout(primary: primary) { makeModel($0) }
        #expect(layout.panes.count == 1)
        #expect(!layout.isDual)
        #expect(layout.active === primary)
        #expect(layout.inactive == nil)
        #expect(layout.transferTarget == nil)
    }

    @Test func showDualOpensSameFolderFirstTime() throws {
        let (dir, a, _) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        #expect(layout.isDual)
        #expect(samePath(layout.panes[1].currentURL, layout.panes[0].currentURL))
        #expect(layout.activeIndex == 0)
    }

    @Test func showDualReopensRememberedFolder() async throws {
        let (dir, a, b) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        await layout.panes[1].navigate(to: b)
        layout.showSingle()
        layout.showDual()
        #expect(samePath(layout.panes[1].currentURL, b))
    }

    @Test func showSingleKeepsActivePane() async throws {
        let (dir, a, b) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        await layout.panes[1].navigate(to: b)
        let right = layout.panes[1]
        layout.activate(right)
        layout.showSingle()
        #expect(layout.panes.count == 1)
        #expect(layout.panes[0] === right)
        #expect(layout.activeIndex == 0)
        #expect(samePath(layout.rememberedSecondFolder!, a))
    }

    @Test func activeFollowsActivation() throws {
        let (dir, a, _) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        let left = layout.panes[0]
        let right = layout.panes[1]
        layout.activate(right)
        #expect(layout.active === right)
        #expect(layout.inactive === left)
        layout.activate(makeModel(a))
        #expect(layout.active === right)
    }

    @Test func switchActiveRequestsFocus() throws {
        let (dir, a, _) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        let serial = layout.focusSerial
        layout.switchActive()
        #expect(layout.activeIndex == 1)
        #expect(layout.focusSerial == serial + 1)
        #expect(layout.focusTarget == ObjectIdentifier(layout.panes[1]))
    }

    @Test func searchTextIsPerPane() throws {
        let (dir, a, _) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        let left = layout.panes[0]
        let right = layout.panes[1]
        layout.setSearchText("a", for: left)
        layout.setSearchText("b", for: right)
        #expect(layout.searchText(for: left) == "a")
        #expect(layout.searchText(for: right) == "b")
        layout.showSingle()
        #expect(layout.searchText(for: right) == "")
        #expect(layout.searchText(for: left) == "a")
    }

    @Test func transferTargetIsOtherPaneFolder() throws {
        let (dir, a, _) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        #expect(layout.transferTarget == layout.panes[1].currentURL)
    }

    @Test func swapFoldersExchangesAndBackRestores() async throws {
        let (dir, a, b) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        await layout.panes[1].navigate(to: b)
        await layout.swapFolders()
        #expect(samePath(layout.panes[0].currentURL, b))
        #expect(samePath(layout.panes[1].currentURL, a))
        await layout.panes[0].goBack()
        #expect(samePath(layout.panes[0].currentURL, a))
    }

    @Test func sameFolderInOtherPane() async throws {
        let (dir, a, b) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        await layout.panes[1].navigate(to: b)
        await layout.showActiveFolderInOtherPane()
        #expect(samePath(layout.panes[1].currentURL, a))
    }
}
