import AppKit
import Foundation
import Testing

@testable import MacCommanderCore

/// Polls until `condition` holds or the deadline passes. The deadline is generous: it only costs time when the
/// condition never holds, and a busy CI runner can take seconds where a Mac takes milliseconds.
@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
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

/// Creates many files off the main actor, so the setup of one test doesn't stall the main actor that the
/// other (parallel) tests' timing depends on.
@concurrent
private func createEmptyFiles(_ names: [String], in folder: URL) async {
    for name in names {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
    }
}

/// Removes a big folder off the main actor (`TemporaryDirectory` would remove it in `deinit`, on the main
/// actor of a `@MainActor` test, stalling the other tests' main-actor work for a noticeable time).
@concurrent
private func removeOffMain(_ folder: URL) async {
    try? FileManager.default.removeItem(at: folder)
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

/// Path queries whose `info` blocks its thread, as a hung stat would, until the main actor answers a ping. A
/// check that held the main actor could never be answered; it gives up after ten seconds and counts a miss.
private final class BlockingPathQueries: PathQueriesProvider, @unchecked Sendable {
    // @unchecked: `checks` and `misses` are only touched while holding `lock`.
    private let lock = NSLock()
    private var checks = 0
    private var misses = 0

    var checkCount: Int { lock.withLock { checks } }
    var missedPings: Int { lock.withLock { misses } }

    @concurrent func info(_ url: URL) async -> PathInfo {
        let missed = !Self.blockUntilMainAnswers()
        lock.withLock {
            checks += 1
            if missed { misses += 1 }
        }
        return PathQueries.infoNow(url)
    }

    /// Blocks the calling thread until the main queue runs a ping; false when it doesn't within ten seconds.
    private static func blockUntilMainAnswers() -> Bool {
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { answered.signal() }
        return answered.wait(timeout: .now() + 10) == .success
    }

    @concurrent func archiveLocation(_ url: URL) async -> ArchiveLocation? { ArchivePath.split(url) }
    @concurrent func nearestExistingFolder(_ url: URL) async -> URL { PathUtilities.nearestExistingAncestor(of: url) }
    @concurrent func canonicalPath(_ url: URL) async -> String { await PathQueries.canonicalPath(url) }
    @concurrent func resolvingSymlink(_ url: URL) async -> URL { await PathQueries.resolvingSymlink(url) }
    @concurrent func entryExists(_ url: URL) async -> Bool { await PathQueries.entryExists(url) }
}

/// Path queries whose `info` for one path waits until `release()`, like a stat on a stalled share.
private final class StallingPathQueries: PathQueriesProvider, @unchecked Sendable {
    // @unchecked: `released` and `waiters` are only touched while holding `lock`.
    private let stalledPath: String
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stalls = 0

    init(stalling url: URL) { stalledPath = url.standardizedFileURL.path }

    var stallCount: Int { lock.withLock { stalls } }

    func release() {
        let resumed = lock.withLock {
            released = true
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    func info(_ url: URL) async -> PathInfo {
        if url.standardizedFileURL.path == stalledPath {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    stalls += 1
                    if released { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return await PathQueries.info(url)
    }
    func archiveLocation(_ url: URL) async -> ArchiveLocation? { await PathQueries.archiveLocation(url) }
    func nearestExistingFolder(_ url: URL) async -> URL { await PathQueries.nearestExistingFolder(url) }
    func canonicalPath(_ url: URL) async -> String { await PathQueries.canonicalPath(url) }
    func resolvingSymlink(_ url: URL) async -> URL { await PathQueries.resolvingSymlink(url) }
    func entryExists(_ url: URL) async -> Bool { await PathQueries.entryExists(url) }
}

@MainActor
@Suite struct BrowserModelTests {
    private let defaults = TemporaryDefaults()

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
        ViewSettingsStore(defaults: defaults.make())
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

    @Test func replaceStartHasNoBackEntry() async throws {
        let dir = try TemporaryDirectory()
        let home = try dir.folder("home")
        let preferred = try dir.folder("preferred")
        try dir.file("preferred/inside.txt")
        let file = try dir.file("file.txt")
        let model = BrowserModel(start: home, settings: makeStore())
        await model.reload()

        #expect(await model.replaceStart(with: file) == false)
        #expect(await model.replaceStart(with: dir.url.appendingPathComponent("missing")) == false)
        #expect(samePath(model.currentURL, home))

        #expect(await model.replaceStart(with: preferred))
        #expect(samePath(model.currentURL, preferred))
        #expect(model.history.canGoBack == false)
        #expect(names(model) == ["inside.txt"])

        // Once the user navigated, the start stays.
        let other = BrowserModel(start: home, settings: makeStore())
        await other.reload()
        await other.navigate(to: dir.url)
        #expect(await other.replaceStart(with: preferred) == false)
        #expect(samePath(other.currentURL, dir.url))
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
        await createEmptyFiles((0..<3000).map { "f\($0).txt" }, in: big)
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
        await removeOffMain(big)
    }

    @Test(.english) func createEmptyFileSelectsAndRequestsRename() async throws {
        let dir = try TemporaryDirectory()
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        let url = try await model.createEmptyFile()

        #expect(url.lastPathComponent == "untitled.txt")
        #expect(model.selection == [url])
        #expect(model.pendingRename == url)
        #expect(model.items.contains { $0.url == url })
    }

    @Test(.english) func createFolderSelectsAndRequestsRename() async throws {
        let dir = try TemporaryDirectory()
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        let url = try await model.createFolder()

        #expect(url.lastPathComponent == "untitled folder")
        #expect(model.selection == [url])
        #expect(model.pendingRename == url)
        #expect(model.items.contains { $0.url == url && $0.isDirectory })
    }

    /// The name comes from the caller's language, although the folder is created off the main actor.
    @Test func createFolderUsesTheCallersLanguage() async throws {
        let dir = try TemporaryDirectory()
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        let url = try await L10n.$localeOverride.withValue("de") { try await model.createFolder() }

        #expect(url.lastPathComponent == "Neuer Ordner")
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

    @Test func openExternallyHandsEachURLToTheOpener() async throws {
        let dir = try TemporaryDirectory()
        let recorder = OpenRecorder()
        let model = BrowserModel(start: dir.url, settings: makeStore()) { recorder.opened.append($0) }
        let first = URL(fileURLWithPath: "/x/a.md")
        let second = URL(fileURLWithPath: "/x/b.txt")

        model.openExternally([first, second])

        #expect(recorder.opened == [first, second])
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

    @Test(.english) func navigatingAwayDuringCreateReloadLeavesSelectionAlone() async throws {
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
        await createEmptyFiles((0..<2000).map { "f\($0).txt" }, in: dir.url)
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
        await removeOffMain(dir.url)
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

    @Test(.english) func renameAndCreateAreUndoable() async throws {
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
        // The folder watcher stays silent for the whole test, so only the notification can reload.
        model.watcherTiming = (debounce: .seconds(60), maxLatency: .seconds(60))
        await model.reload()

        _ = await center.transfer([a], into: dst, mode: .copy) { _ in
            ConflictDecision(choice: .keepBoth, applyToAll: true)
        }
        #expect(await waitUntil { names(model) == ["a.txt"] })
    }

    @Test(.english) func selectAfterOperationSelectsItems() async throws {
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

    @Test func selectRightAfterCreation() async throws {
        let dir = try TemporaryDirectory()
        let work = try dir.folder("work")
        try dir.folder("other")
        let a = try dir.file("work/a.txt")
        try dir.file("work/b.txt")
        let elsewhere = try dir.file("other/a.txt")
        let model = BrowserModel(start: work, settings: makeStore())

        await model.select([a, elsewhere])

        let item = try #require(model.items.first { $0.url.lastPathComponent == "a.txt" })
        #expect(model.selection == [item.url])
    }

    @Test func selectAndRevealAskToScrollSelectionIntoView() async throws {
        let dir = try TemporaryDirectory()
        let work = try dir.folder("work")
        let a = try dir.file("work/a.txt")
        let model = BrowserModel(start: work, settings: makeStore())
        #expect(!model.scrollsSelectionIntoView)

        await model.select([a])
        #expect(model.scrollsSelectionIntoView)

        model.scrollsSelectionIntoView = false
        #expect(await model.reveal(a))
        #expect(model.scrollsSelectionIntoView)

        _ = await model.navigate(to: dir.url)
        #expect(!model.scrollsSelectionIntoView)
    }

    @Test func selectSurvivesConcurrentReload() async throws {
        for selectFirst in [true, false] {
            let dir = try TemporaryDirectory()
            let work = try dir.folder("work")
            let a = try dir.file("work/a.txt")
            try dir.file("work/b.txt")
            let model = BrowserModel(start: work, settings: makeStore())

            let first = Task { @MainActor in
                if selectFirst { await model.select([a]) } else { await model.reload() }
            }
            await Task.yield()
            let second = Task { @MainActor in
                if selectFirst { await model.reload() } else { await model.select([a]) }
            }
            await first.value
            await second.value

            let item = try #require(model.items.first { $0.url.lastPathComponent == "a.txt" })
            #expect(model.selection == [item.url])
        }
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
        let queries = BlockingPathQueries()
        let model = BrowserModel(
            start: URL(fileURLWithPath: "/"), settings: makeStore(),
            loader: DirectoryLoader(), pathQueries: queries)

        await model.navigate(to: dir.url)

        #expect(queries.checkCount > 0)
        #expect(queries.missedPings == 0)
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

    @Test func lastClickWinsOverStalledOpen() async throws {
        let dir = try TemporaryDirectory()
        // A symlink to a folder: `open` checks it off the main actor before it navigates, and that check stalls.
        let target = try dir.folder("target")
        let stalled = dir.url.appendingPathComponent("stalled")
        try FileManager.default.createSymbolicLink(at: stalled, withDestinationURL: target)
        let home = try dir.folder("home")
        try dir.file("home/h.txt")
        let queries = StallingPathQueries(stalling: stalled)
        let model = BrowserModel(
            start: dir.url, settings: makeStore(), loader: DirectoryLoader(), pathQueries: queries)
        await model.reload()
        let item = try #require(model.items.first { $0.url.lastPathComponent == "stalled" })
        #expect(!item.isDirectory)

        let opening = Task { await model.open(item) }
        #expect(await waitUntil { queries.stallCount == 1 })
        await model.navigate(to: home)
        #expect(samePath(model.currentURL, home))

        queries.release()
        await opening.value
        #expect(samePath(model.currentURL, home))
        #expect(names(model) == ["h.txt"])
    }

    @Test func revealThroughSymlinkedFolderSelectsTarget() async throws {
        let dir = try TemporaryDirectory()
        let real = try dir.folder("real")
        try dir.file("real/x.md")
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let model = BrowserModel(start: dir.url, settings: makeStore())
        await model.reload()

        #expect(await model.reveal(link.appendingPathComponent("x.md")))

        #expect(samePath(model.currentURL.resolvingSymlinksInPath(), real.resolvingSymlinksInPath()))
        let item = try #require(model.items.first { $0.url.lastPathComponent == "x.md" })
        #expect(model.selection == [item.url])
    }
}
