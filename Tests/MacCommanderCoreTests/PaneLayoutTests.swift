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

    @Test func renamingIsPerPaneAndDroppedWithThePane() throws {
        let (dir, a, _) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        let right = layout.panes[1]
        layout.setRenaming(true, for: right)
        #expect(!layout.isActiveRenaming)
        layout.activate(right)
        #expect(layout.isActiveRenaming)
        layout.setRenaming(false, for: right)
        #expect(!layout.isActiveRenaming)
        layout.setRenaming(true, for: layout.panes[0])
        layout.showSingle()
        #expect(!layout.isActiveRenaming)
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

    @Test func swapFoldersDoesNotWaitForSlowPane() async throws {
        let (dir, a, b) = try folders()
        defer { withExtendedLifetime(dir) {} }
        let layout = makeLayout(start: a)
        layout.showDual()
        let left = layout.panes[0]
        let right = layout.panes[1]
        await left.reload()
        await right.navigate(to: b)
        let gate = Gate()
        // The active (left) pane's listing of its new folder hangs, like a dead server.
        left.afterListingHook = { url in
            if samePath(url, b) { await gate.wait() }
        }

        let swap = Task { await layout.swapFolders() }
        let otherArrived = await waitUntil {
            right.listedURL.map { samePath($0, a) } == true && !right.isLoading
        }
        #expect(otherArrived)
        // The slow pane is still listing its new folder.
        #expect(left.listedURL.map { samePath($0, a) } == true)
        gate.open()
        await swap.value
        #expect(samePath(left.currentURL, b))
        #expect(samePath(right.currentURL, a))
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
