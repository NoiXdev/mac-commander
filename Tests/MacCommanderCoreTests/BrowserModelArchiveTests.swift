import Foundation
import Testing

@testable import MacCommanderCore

/// Polls until `condition` holds or the deadline passes.
@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
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
@Suite struct BrowserModelArchiveTests {
    private let defaults = TemporaryDefaults()

    private static let tree: [String: String] = [
        "a.txt": "aaa",
        "img/x.png": "x",
        "img/deep/y.txt": "y",
    ]

    private func makeStore() -> ViewSettingsStore {
        ViewSettingsStore(defaults: defaults.make())
    }

    private func names(_ model: BrowserModel) -> [String] {
        model.items.map(\.name)
    }

    private func makeModel(
        in folder: URL, catalog: ArchiveCatalog = ArchiveCatalog(), recorder: OpenRecorder? = nil
    ) -> BrowserModel {
        BrowserModel(
            start: folder, settings: makeStore(),
            opener: { url in recorder?.opened.append(url) },
            catalog: catalog)
    }

    private func item(named name: String, in model: BrowserModel) throws -> FileItem {
        try #require(model.items.first { $0.name == name })
    }

    @Test func openArchiveShowsRoot() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(Self.tree, format: "zip", in: temp, name: "a.zip")
        let model = makeModel(in: temp.url)
        await model.reload()
        #expect(model.archiveLocation == nil)

        await model.open(try item(named: "a.zip", in: model))

        #expect(samePath(model.currentURL, zip))
        #expect(names(model) == ["a.txt", "img"])
        #expect(model.archiveLocation?.inner == "")
        #expect(model.archiveLocation.map { samePath($0.archive, zip) } == true)
        #expect(model.listedURL.map { samePath($0, zip) } == true)
        #expect(model.loadError == nil)
    }

    @Test func navigateIntoArchiveFolderAndBack() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(Self.tree, format: "zip", in: temp, name: "a.zip")
        let model = makeModel(in: temp.url)
        await model.navigate(to: zip)
        #expect(names(model) == ["a.txt", "img"])

        await model.open(try item(named: "img", in: model))
        #expect(samePath(model.currentURL, zip.appendingPathComponent("img")))
        #expect(names(model) == ["deep", "x.png"])
        #expect(model.archiveLocation?.inner == "img")

        // Files inside an archive are left to the UI.
        await model.open(try item(named: "x.png", in: model))
        #expect(model.archiveLocation?.inner == "img")

        await model.goBack()
        #expect(samePath(model.currentURL, zip))
        #expect(names(model) == ["a.txt", "img"])

        await model.goUp()
        #expect(samePath(model.currentURL, temp.url))
        #expect(model.archiveLocation == nil)
    }

    @Test func goToVirtualPath() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(Self.tree, format: "zip", in: temp, name: "a.zip")
        let model = makeModel(in: temp.url)

        await model.navigate(to: zip.appendingPathComponent("img/deep"))
        #expect(names(model) == ["y.txt"])
        #expect(model.archiveLocation?.inner == "img/deep")

        // A folder missing from the archive falls back to the deepest existing one.
        await model.navigate(to: zip.appendingPathComponent("img/nope/more"))
        #expect(samePath(model.currentURL, zip.appendingPathComponent("img")))
        #expect(names(model) == ["deep", "x.png"])
        #expect(model.archiveLocation?.inner == "img")

        // goUp from a subfolder of a browsed container returns to its root.
        await model.goUp()
        #expect(samePath(model.currentURL, zip))
        #expect(model.archiveLocation?.inner == "")
    }

    @Test func childrenInsideArchive() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(Self.tree, format: "zip", in: temp, name: "a.zip")
        let model = makeModel(in: temp.url)
        await model.navigate(to: zip)

        let children = try await model.children(of: zip.appendingPathComponent("img"))
        #expect(children.map(\.name) == ["deep", "x.png"])
        let deep = try #require(children.first { $0.name == "deep" })
        #expect(try await model.children(of: deep.url).map(\.name) == ["y.txt"])

        // Selected inline-expanded entries survive a reload, though virtual paths don't exist on disk.
        let file = try #require(children.first { $0.name == "x.png" })
        let root = try item(named: "a.txt", in: model)
        model.selection = [file.url, root.url]
        await model.reload()
        #expect(model.selection == [file.url, root.url])
    }

    @Test func encryptedNeedsPassword() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(Self.tree, format: "zip", in: temp, name: "a.zip")
        // Zip headers aren't encrypted, so the listing needs the injected error.
        let model = makeModel(in: temp.url, catalog: ArchiveCatalog(testError: .passwordRequired))
        await model.navigate(to: zip)
        #expect(model.loadError == .archivePasswordRequired(zip))
        #expect(model.items.isEmpty)
        #expect(model.archiveLocation?.inner == "")

        await model.providePassword("secret")
        #expect(model.loadError == nil)
        #expect(names(model) == ["a.txt", "img"])
    }

    @Test func unsupportedFallsBackToOpener() async throws {
        let temp = try TemporaryDirectory()
        let bad = try temp.file("bad.zip", contents: "just some text\nnot an archive\n")
        let recorder = OpenRecorder()
        let model = makeModel(in: temp.url, recorder: recorder)
        await model.reload()

        await model.open(try item(named: "bad.zip", in: model))

        #expect(recorder.opened.map(\.lastPathComponent) == ["bad.zip"])
        #expect(recorder.opened.first.map { samePath($0, bad) } == true)
        #expect(samePath(model.currentURL, temp.url))
        #expect(model.archiveLocation == nil)
        #expect(model.loadError == nil)
        #expect(names(model) == ["bad.zip"])
    }

    @Test func browseContentsUnreadableShowsError() async throws {
        let temp = try TemporaryDirectory()
        let doc = try temp.file("x.docx", contents: "not a zip\n")
        let recorder = OpenRecorder()
        let model = makeModel(in: temp.url, recorder: recorder)
        await model.reload()

        await model.browseContents(try item(named: "x.docx", in: model))

        #expect(recorder.opened.isEmpty)
        #expect(samePath(model.currentURL, doc))
        guard case .archiveUnreadable(let url, _) = model.loadError else {
            Issue.record("expected archiveUnreadable, got \(String(describing: model.loadError))")
            return
        }
        #expect(samePath(url, doc))
        #expect(model.loadError?.message.hasPrefix("“x.docx” can’t be opened: ") == true)
    }

    @Test func browseContentsOpensContainers() async throws {
        let temp = try TemporaryDirectory()
        let docx = try ArchiveFixtures.makeArchive(["word/document.xml": "<x/>"], format: "zip", in: temp, name: "d.docx")
        let model = makeModel(in: temp.url)
        await model.reload()
        // .docx isn't a pure archive: navigate(to:) refuses it.
        await model.navigate(to: docx)
        #expect(samePath(model.currentURL, temp.url))

        await model.browseContents(try item(named: "d.docx", in: model))
        #expect(samePath(model.currentURL, docx))
        #expect(names(model) == ["word"])
    }

    @Test func archiveDeletedFallsBackToParent() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(Self.tree, format: "zip", in: temp, name: "a.zip")
        let model = makeModel(in: temp.url)
        await model.navigate(to: zip.appendingPathComponent("img"))
        #expect(names(model) == ["deep", "x.png"])

        try FileManager.default.removeItem(at: zip)

        #expect(await waitUntil { samePath(model.currentURL, temp.url) && model.archiveLocation == nil })
        #expect(model.loadError == nil)
        #expect(!names(model).contains("a.zip"))
        #expect(model.listedURL.map { samePath($0, temp.url) } == true)
    }

    @Test func archiveReplacedRelists() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(Self.tree, format: "zip", in: temp, name: "a.zip")
        let model = makeModel(in: temp.url)
        await model.navigate(to: zip)
        #expect(names(model) == ["a.txt", "img"])

        var tree = Self.tree
        tree["new.txt"] = "new"
        let replacement = try ArchiveFixtures.makeArchive(tree, format: "zip", in: temp, name: "b.zip")
        #expect(rename(replacement.path, zip.path) == 0)

        #expect(await waitUntil { names(model) == ["a.txt", "img", "new.txt"] })
        #expect(samePath(model.currentURL, zip))
    }

    @Test func writesRefusedInsideArchive() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(Self.tree, format: "zip", in: temp, name: "a.zip")
        let model = makeModel(in: temp.url)
        await model.navigate(to: zip)
        let entry = try item(named: "a.txt", in: model)

        await #expect(throws: CocoaError(.fileWriteNoPermission)) { _ = try await model.createFolder() }
        await #expect(throws: CocoaError(.fileWriteNoPermission)) { _ = try await model.createEmptyFile() }
        await #expect(throws: RenameError.self) { _ = try await model.rename(entry.url, to: "b.txt") }
        #expect(names(model) == ["a.txt", "img"])
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int
        #expect(size ?? 0 > 0)
    }
}
