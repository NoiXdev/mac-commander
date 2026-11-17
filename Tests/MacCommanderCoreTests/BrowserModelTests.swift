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
@Suite struct BrowserModelTests {
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
}
