import AppKit
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

@MainActor
private final class OpenRecorder {
    var opened: [URL] = []
}

private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
}

@MainActor
private final class Flag {
    var isSet = false
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
private final class Counter {
    var count = 0
}

/// Path queries that take a second each time `info` is asked, like a stat on an unresponsive server.
private struct BlockingPathQueries: PathQueriesProvider {
    @concurrent func info(_ url: URL) async -> PathInfo {
        usleep(1_000_000)  // Blocks the thread, as a hung stat would.
        return PathQueries.infoNow(url)
    }
    @concurrent func archiveLocation(_ url: URL) async -> ArchiveLocation? { ArchivePath.split(url) }
    @concurrent func nearestExistingFolder(_ url: URL) async -> URL { PathUtilities.nearestExistingAncestor(of: url) }
    @concurrent func canonicalPath(_ url: URL) async -> String { await PathQueries.canonicalPath(url) }
    @concurrent func resolvingSymlink(_ url: URL) async -> URL { await PathQueries.resolvingSymlink(url) }
    @concurrent func entryExists(_ url: URL) async -> Bool { await PathQueries.entryExists(url) }
}

@MainActor
@Suite struct BrowserModelTests {
    /// Makes the first listing of `folder` stale by navigating to `other` before it is checked.
    private func navigateAwayDuringNextListing(of folder: URL, to other: URL, in model: BrowserModel) {
        let fired = Flag()
        model.afterListingHook = { [weak model] url in
            guard !fired.isSet, samePath(url, folder), let model else { return }
            fired.isSet = true
            await model.navigate(to: other)
        }
    }

    private func makeStore() -> ViewSettingsStore {
        ViewSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func names(_ model: BrowserModel) -> [String] {
        model.items.map(\.url.lastPathComponent)
    }

    @Test func navigateLoadsSortedItems() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("file10.txt")
        try dir.file("file2.txt")
        try dir.folder("Beta")
        try dir.file("alpha.txt")
        let model = BrowserModel(start: URL(fileURLWithPath: "/"), settings: makeStore())

        await model.navigate(to: dir.url)

        #expect(samePath(model.currentURL, dir.url))
        #expect(names(model) == ["alpha.txt", "Beta", "file2.txt", "file10.txt"])
        #expect(model.loadError == nil)
        #expect(model.isLoading == false)
    }

    @Test func navigateToFileOrMissingPathDoesNothing() async throws {
        let dir = try TemporaryDirectory()
        let file = try dir.file("a.txt")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        await model.navigate(to: file)
        await model.navigate(to: dir.url.appendingPathComponent("missing"))

        #expect(samePath(model.currentURL, dir.url))
        #expect(model.history.canGoBack == false)
        #expect(names(model) == ["a.txt"])
    }

    @Test func recreatedFolderIsWatchedAgain() async throws {
        let dir = try TemporaryDirectory()
        let work = try dir.folder("work")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        await model.navigate(to: work)

        try FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        await model.reload()
        // Let stale events from the old folder drain (longer than the watcher's 1 s max latency).
        try await Task.sleep(for: .milliseconds(1500))
        try dir.file("work/new.txt")

        #expect(await waitUntil { names(model) == ["new.txt"] })
    }

    @Test func goBackAndForward() async throws {
        let dir = try TemporaryDirectory()
        let a = try dir.folder("a")
        let b = try dir.folder("b")
        try dir.file("b/inside.txt")
        let model = BrowserModel(start: a, settings: makeStore())
        await model.reload()
        await model.navigate(to: b)

        await model.goBack()
        #expect(samePath(model.currentURL, a))
        #expect(model.items.isEmpty)

        await model.goForward()
        #expect(samePath(model.currentURL, b))
        #expect(names(model) == ["inside.txt"])
    }

    @Test func goUpFromSubfolder() async throws {
        let dir = try TemporaryDirectory()
        let sub = try dir.folder("sub")
        let model = BrowserModel(start: sub, settings: makeStore())
        await model.reload()

        await model.goUp()

        #expect(samePath(model.currentURL, dir.url))
        #expect(names(model) == ["sub"])
        #expect(model.history.canGoBack)
    }

    @Test func permissionDeniedSetsLoadError() async throws {
        let dir = try TemporaryDirectory()
        let locked = try dir.folder("locked")
        try dir.file("locked/secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        await model.navigate(to: locked)

        #expect(model.loadError == .permissionDenied(model.currentURL))
        #expect(model.items.isEmpty)

        await model.goBack()
        #expect(model.loadError == nil)
        #expect(names(model) == ["locked"])
    }

    @Test func deletedCurrentFolderFallsBackToAncestor() async throws {
        let dir = try TemporaryDirectory()
        let a = try dir.folder("a")
        let b = try dir.folder("a/b")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        await model.navigate(to: b)

        try FileManager.default.removeItem(at: b)
        await model.reload()

        #expect(samePath(model.currentURL, a))
        #expect(model.loadError == nil)
        #expect(model.items.isEmpty)
    }

    @Test func staleLoadDoesNotOverwriteNewerOne() async throws {
        let dir = try TemporaryDirectory()
        let big = try dir.folder("big")
        for i in 0..<3000 { try dir.file("big/f\(i).txt") }
        let small = try dir.folder("small")
        try dir.file("small/only.txt")
        let model = BrowserModel(start: dir.url, settings: makeStore())

        let first = Task { await model.navigate(to: big) }
        let second = Task { await model.navigate(to: small) }
        await first.value
        await second.value

        #expect(samePath(model.currentURL, small))
        #expect(names(model) == ["only.txt"])
        #expect(model.isLoading == false)
    }

    @Test func createEmptyFileSelectsAndRequestsRename() async throws {
        let dir = try TemporaryDirectory()
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        let url = try await model.createEmptyFile()

        #expect(url.lastPathComponent == "untitled.txt")
        #expect(model.selection == [url])
        #expect(model.pendingRename == url)
        #expect(model.items.contains { $0.url == url })
    }

    @Test func createFolderSelectsAndRequestsRename() async throws {
        let dir = try TemporaryDirectory()
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        let url = try await model.createFolder()

        #expect(url.lastPathComponent == "untitled folder")
        #expect(model.selection == [url])
        #expect(model.pendingRename == url)
        #expect(model.items.contains { $0.url == url && $0.isDirectory })
    }

    @Test func renameUpdatesItemsAndSelection() async throws {
        let dir = try TemporaryDirectory()
        let old = try dir.file("old.txt")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        model.selection = [model.items[0].url]

        let renamed = try await model.rename(old, to: "new.txt")

        #expect(renamed.lastPathComponent == "new.txt")
        #expect(names(model) == ["new.txt"])
        #expect(model.selection == [renamed])
        #expect(model.items.map(\.url) == [renamed])
        await #expect(throws: RenameError.emptyName) { try await model.rename(renamed, to: " ") }
    }

    @Test func externalChangeTriggersReload() async throws {
        let dir = try TemporaryDirectory()
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        #expect(model.items.isEmpty)

        try dir.file("external.txt")

        #expect(await waitUntil { names(model) == ["external.txt"] })
    }

    @Test func vanishedItemsLeaveSelection() async throws {
        let dir = try TemporaryDirectory()
        let keep = try dir.file("keep.txt")
        let gone = try dir.file("gone.txt")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        model.selection = Set(model.items.map(\.url))

        try FileManager.default.removeItem(at: gone)
        await model.reload()

        #expect(model.selection.map(\.lastPathComponent) == [keep.lastPathComponent])
    }

    @Test func toggleHiddenShowsDotFiles() async throws {
        let dir = try TemporaryDirectory()
        try dir.file(".hidden")
        try dir.file("visible.txt")
        let store = makeStore()
        let model = BrowserModel(start: dir.url, settings: store)
        await model.reload()
        #expect(names(model) == ["visible.txt"])

        store.settings.showHiddenFiles = true
        #expect(await waitUntil { names(model) == [".hidden", "visible.txt"] })

        store.settings.showHiddenFiles = false
        #expect(await waitUntil { names(model) == ["visible.txt"] })
    }

    @Test func sortChangeResortsItems() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("a.txt")
        try dir.file("b.txt")
        try dir.file("c.txt")
        let store = makeStore()
        let model = BrowserModel(start: dir.url, settings: store)
        await model.reload()
        #expect(names(model) == ["a.txt", "b.txt", "c.txt"])

        store.settings.sortOrder.ascending = false
        #expect(await waitUntil { names(model) == ["c.txt", "b.txt", "a.txt"] })

        // A second change proves observation is re-armed after the first.
        store.settings.sortOrder.ascending = true
        #expect(await waitUntil { names(model) == ["a.txt", "b.txt", "c.txt"] })
    }

    @Test func childrenAreSortedAndFiltered() async throws {
        let dir = try TemporaryDirectory()
        let sub = try dir.folder("sub")
        try dir.file("sub/file10")
        try dir.file("sub/file2")
        try dir.file("sub/.dot")
        let model = BrowserModel(start: dir.url, settings: makeStore())

        let children = try await model.children(of: sub)

        #expect(children.map(\.url.lastPathComponent) == ["file2", "file10"])
    }

    @Test func openFileCallsOpener() async throws {
        let dir = try TemporaryDirectory()
        let file = try dir.file("doc.txt")
        let recorder = OpenRecorder()
        let model = BrowserModel(start: dir.url, settings: makeStore()) { recorder.opened.append($0) }
        await model.reload()

        await model.open(try #require(model.items.first))

        #expect(recorder.opened.count == 1)
        #expect(recorder.opened.first.map { samePath($0, file) } == true)
        #expect(samePath(model.currentURL, dir.url))
    }

    @Test func openDirectoryAndFolderSymlinkNavigate() async throws {
        let dir = try TemporaryDirectory()
        let target = try dir.folder("target")
        try dir.file("target/inside.txt")
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let recorder = OpenRecorder()
        let model = BrowserModel(start: dir.url, settings: makeStore()) { recorder.opened.append($0) }
        await model.reload()

        let linkItem = try #require(model.items.first { $0.url.lastPathComponent == "link" })
        #expect(linkItem.isDirectory == false)
        await model.open(linkItem)
        #expect(samePath(model.currentURL, target.resolvingSymlinksInPath()))
        #expect(names(model) == ["inside.txt"])

        await model.goBack()
        await model.open(try #require(model.items.first { $0.url.lastPathComponent == "target" }))
        #expect(samePath(model.currentURL, target))
        #expect(recorder.opened.isEmpty)
    }

    @Test func navigatingAwayDuringCreateReloadLeavesSelectionAlone() async throws {
        let dir = try TemporaryDirectory()
        let first = try dir.folder("first")
        let other = try dir.folder("other")
        try dir.file("other/untitled.txt")
        let model = BrowserModel(start: first, settings: makeStore())
        await model.reload()
        navigateAwayDuringNextListing(of: first, to: other, in: model)

        let url = try await model.createEmptyFile()

        #expect(samePath(url.deletingLastPathComponent(), first))
        #expect(samePath(model.currentURL, other))
        #expect(model.pendingRename == nil)
        #expect(model.selection.isEmpty)
        #expect(names(model) == ["untitled.txt"])
    }

    @Test func navigatingAwayDuringRenameReloadReturnsRenamedURL() async throws {
        let dir = try TemporaryDirectory()
        let first = try dir.folder("first")
        let old = try dir.file("first/a.txt")
        let other = try dir.folder("other")
        try dir.file("other/b.txt")
        let model = BrowserModel(start: first, settings: makeStore())
        await model.reload()
        navigateAwayDuringNextListing(of: first, to: other, in: model)

        let renamed = try await model.rename(old, to: "b.txt")

        #expect(samePath(renamed.deletingLastPathComponent(), first))
        #expect(samePath(model.currentURL, other))
        #expect(!model.selection.contains { model.items.map(\.url).contains($0) })
    }

    @Test func pruningKeepsManySelectedEntriesSharingOneParent() async throws {
        let dir = try TemporaryDirectory()
        for i in 0..<2000 { try dir.file("f\(i).txt") }
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        // Spelled differently from the loader's URLs (e.g. /var vs /private/var).
        model.selection = Set((0..<2000).map { dir.url.appendingPathComponent("f\($0).txt") })

        try FileManager.default.removeItem(at: dir.url.appendingPathComponent("f7.txt"))
        let start = ContinuousClock.now
        await model.reload()

        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(model.selection.count == 1999)
        #expect(model.selection == Set(model.items.map(\.url)))
    }

    @Test func deletedCurrentFolderFallsBackViaWatcher() async throws {
        let dir = try TemporaryDirectory()
        let a = try dir.folder("a")
        let b = try dir.folder("a/b")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        await model.navigate(to: b)

        try FileManager.default.removeItem(at: b)

        #expect(await waitUntil { samePath(model.currentURL, a) })
        #expect(model.loadError == nil)
    }

    @Test func unmountOfCurrentVolumeFallsBack() async throws {
        let dir = try TemporaryDirectory()
        let volume = try dir.folder("volume")
        let inner = try dir.folder("volume/inner")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        await model.navigate(to: inner)

        // Moving the parent away doesn't notify the watcher on `inner`; only the unmount does.
        try FileManager.default.moveItem(at: volume, to: dir.url.appendingPathComponent("moved"))
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didUnmountNotification, object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])

        #expect(await waitUntil { samePath(model.currentURL, dir.url) })
    }

    @Test func navigationClearsSelection() async throws {
        let dir = try TemporaryDirectory()
        let a = try dir.folder("a")
        try dir.file("a/x.txt")
        let b = try dir.folder("b")
        let model = BrowserModel(start: a, settings: makeStore())
        await model.reload()
        model.selection = Set(model.items.map(\.url))
        model.pendingRename = model.items.first?.url

        await model.navigate(to: b)

        #expect(model.selection.isEmpty)
        #expect(model.pendingRename == nil)
    }

    @Test func goBackClearsSelection() async throws {
        let dir = try TemporaryDirectory()
        let a = try dir.folder("a")
        let b = try dir.folder("b")
        try dir.file("b/y.txt")
        let model = BrowserModel(start: a, settings: makeStore())
        await model.reload()
        await model.navigate(to: b)
        model.selection = Set(model.items.map(\.url))
        #expect(model.selection.count == 1)

        await model.goBack()

        #expect(model.selection.isEmpty)
    }

    @Test func reloadKeepsSelection() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("x.txt")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        let selected = Set(model.items.map(\.url))
        model.selection = selected

        await model.reload()

        #expect(model.selection == selected)
        #expect(!selected.isEmpty)
    }

    @Test func ancestorFallbackClearsSelection() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("a/x.txt")
        let a = dir.url.appendingPathComponent("a")
        let b = try dir.folder("a/b")
        try dir.file("a/b/inner.txt")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        await model.navigate(to: b)
        model.selection = Set(model.items.map(\.url))
        // Also select an entry in the fallback folder: it must not survive the fallback.
        model.selection.insert(a.appendingPathComponent("x.txt"))

        try FileManager.default.removeItem(at: b)
        await model.reload()

        #expect(samePath(model.currentURL, a))
        #expect(model.selection.isEmpty)
    }

    @Test func listedURLFollowsPublishedListing() async throws {
        let dir = try TemporaryDirectory()
        let a = try dir.folder("a")
        let b = try dir.folder("b")
        try dir.file("b/y.txt")
        let model = BrowserModel(start: a, settings: makeStore())
        #expect(model.listedURL == nil)
        await model.reload()
        #expect(model.listedURL == model.currentURL)

        var duringListing: URL?
        model.afterListingHook = { [weak model] url in
            guard samePath(url, b), let model else { return }
            duringListing = model.listedURL
        }
        await model.navigate(to: b)

        #expect(duringListing.map { samePath($0, a) } == true)
        #expect(model.listedURL == model.currentURL)
        #expect(names(model) == ["y.txt"])
    }

    @Test func selectionOutsideCurrentFolderIsPruned() async throws {
        let dir = try TemporaryDirectory()
        let a = try dir.folder("a")
        let x = try dir.file("a/x.txt")
        let b = try dir.folder("b")
        let model = BrowserModel(start: a, settings: makeStore())
        await model.reload()
        model.selection = [x]
        await model.navigate(to: b)

        model.selection = [x]
        await model.reload()

        #expect(model.selection.isEmpty)
    }

    @Test func selectionInExpandedSubfolderSurvivesReload() async throws {
        let dir = try TemporaryDirectory()
        try dir.folder("sub")
        let inner = try dir.file("sub/inner.txt")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        model.selection = [inner]
        await model.reload()

        #expect(model.selection == [inner])
    }

    @Test func changesDuringSlowLoadCoalesceIntoOneFollowUp() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("x.txt")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        let gate = Gate()
        let listings = Counter()
        model.afterListingHook = { _ in
            listings.count += 1
            if listings.count == 1 { await gate.wait() }
        }

        let first = Task { await model.reload() }
        #expect(await waitUntil { listings.count == 1 })
        for _ in 0..<3 { await model.directoryDidChange() }
        gate.open()
        await first.value

        #expect(names(model) == ["x.txt"])
        #expect(await waitUntil { listings.count == 2 && !model.isLoading })
        try await Task.sleep(for: .milliseconds(300))
        #expect(listings.count == 2)
        #expect(names(model) == ["x.txt"])
    }

    // MARK: - File operation center

    private func makeCenter(trash trashFolder: URL) -> FileOperationCenter {
        let trash = fakeTrash(into: trashFolder)
        return FileOperationCenter(undo: FileUndoStack(trash: trash), trash: trash)
    }

    @Test func renameAndCreateAreUndoable() async throws {
        let dir = try TemporaryDirectory()
        let trashFolder = try dir.folder("Trash")
        let work = try dir.folder("work")
        let center = makeCenter(trash: trashFolder)
        let model = BrowserModel(start: work, settings: makeStore(), operations: center)
        await model.reload()

        let created = try await model.createEmptyFile()
        #expect(center.undo.undoTitle == "New File")
        _ = try await model.rename(created, to: "x.txt")
        #expect(center.undo.undoTitle == "Rename")

        _ = try await center.performUndo()
        _ = try await center.performUndo()
        let left = try FileManager.default.contentsOfDirectory(atPath: work.path)
        #expect(left.isEmpty)
        let trashed = try FileManager.default.contentsOfDirectory(atPath: trashFolder.path)
        #expect(trashed.count == 1)
    }

    @Test func operationInCurrentFolderReloads() async throws {
        let dir = try TemporaryDirectory()
        try dir.folder("src")
        let dst = try dir.folder("dst")
        let a = try dir.file("src/a.txt")
        let center = makeCenter(trash: try dir.folder("Trash"))
        let model = BrowserModel(start: dst, settings: makeStore(), operations: center)
        await model.reload()

        _ = await center.transfer([a], into: dst, mode: .copy) { _ in
            ConflictDecision(choice: .keepBoth, applyToAll: true)
        }
        // The folder watcher debounces for 200 ms; only the notification can be this fast.
        #expect(await waitUntil(timeout: 0.15) { names(model) == ["a.txt"] })
    }

    @Test func selectAfterOperationSelectsItems() async throws {
        let dir = try TemporaryDirectory()
        let work = try dir.folder("work")
        let a = try dir.file("work/a.txt")
        let center = makeCenter(trash: try dir.folder("Trash"))
        let model = BrowserModel(start: work, settings: makeStore(), operations: center)
        await model.reload()

        let result = await center.duplicate([a])
        await model.selectAfterOperation(result.completed.map(\.destination))

        let copy = try #require(model.items.first { $0.url.lastPathComponent == "a copy.txt" })
        #expect(model.selection == [copy.url])
    }

    @Test func revealNavigatesAndSelects() async throws {
        let dir = try TemporaryDirectory()
        try dir.folder("sub")
        let file = try dir.file("sub/x.md")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        #expect(await model.reveal(file))

        #expect(samePath(model.currentURL, dir.url.appendingPathComponent("sub")))
        let item = try #require(model.items.first { $0.url.lastPathComponent == "x.md" })
        #expect(model.selection == [item.url])
    }

    @Test func revealIgnoresMissingTargets() async throws {
        let dir = try TemporaryDirectory()
        try dir.folder("sub")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        #expect(await model.reveal(dir.url.appendingPathComponent("sub/missing.md")) == false)

        #expect(samePath(model.currentURL, dir.url))
        #expect(model.selection.isEmpty)
    }

    @Test func browserModelNeverStatsOnMainActor() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("a.txt")
        let model = BrowserModel(
            start: URL(fileURLWithPath: "/"), settings: makeStore(),
            loader: DirectoryLoader(), pathQueries: BlockingPathQueries())

        let finished = Flag()
        let started = ContinuousClock.now
        let navigation = Task {
            await model.navigate(to: dir.url)
            finished.isSet = true
        }
        // Ticks while the navigation waits on the blocked path checks (one second each). Other
        // suites share the main actor, so count over the whole wait instead of exactly one second.
        let ticks = Counter()
        while !finished.isSet {
            try await Task.sleep(for: .milliseconds(10))
            ticks.count += 1
        }
        #expect(ContinuousClock.now - started >= .seconds(1))
        #expect(ticks.count >= 50, "ticks: \(ticks.count)")

        await navigation.value
        #expect(samePath(model.currentURL, dir.url))
        #expect(names(model) == ["a.txt"])
    }

    @Test func selectionPruningKeepsDescendantsWithoutStat() async throws {
        let dir = try TemporaryDirectory()
        try dir.folder("sub")
        let inner = try dir.file("sub/inner.txt")
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()
        model.selection = [inner]

        // Gone from disk, but still under the current folder: kept without a stat. Acting on it later
        // fails with a readable error instead.
        try FileManager.default.removeItem(at: inner)
        await model.reload()

        #expect(model.selection == [inner])
    }
}
