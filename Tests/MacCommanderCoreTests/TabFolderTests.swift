import Foundation
import Testing

@testable import MacCommanderCore

/// `BrowserModel.folderForNewTab`: a tab opens only for what a double-click navigates into as a folder,
/// outside an archive.
@MainActor
@Suite struct TabFolderTests {
    private let defaults = TemporaryDefaults()

    private func makeModel(at folder: URL) -> BrowserModel {
        BrowserModel(start: folder, settings: ViewSettingsStore(defaults: defaults.make()), opener: { _ in })
    }

    private func item(named name: String, in model: BrowserModel) throws -> FileItem {
        try #require(model.items.first { $0.url.lastPathComponent == name })
    }

    private func samePath(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    @Test func folderIsATabFolder() async throws {
        let dir = try TemporaryDirectory()
        let folder = try dir.folder("Folder")
        let model = makeModel(at: dir.url)
        await model.reload()

        #expect(samePath(await model.folderForNewTab(try item(named: "Folder", in: model)), folder))
    }

    @Test func symlinkToFolderIsATabFolderAtTheLinksPath() async throws {
        let dir = try TemporaryDirectory()
        let target = try dir.folder("target")
        let link = dir.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let model = makeModel(at: dir.url)
        await model.reload()

        let linkItem = try item(named: "link", in: model)
        #expect(linkItem.isDirectory == false)
        #expect(samePath(await model.folderForNewTab(linkItem), link))
    }

    @Test func packageIsNotATabFolder() async throws {
        let dir = try TemporaryDirectory()
        let app = try dir.folder("Tool.app")
        try dir.folder("Tool.app/Contents")
        let link = dir.url.appendingPathComponent("ToolLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let model = makeModel(at: dir.url)
        await model.reload()

        let package = try item(named: "Tool.app", in: model)
        #expect(package.isPackage)
        #expect(await model.folderForNewTab(package) == nil)
        #expect(await model.folderForNewTab(try item(named: "ToolLink", in: model)) == nil)
    }

    @Test func archiveFileIsNotATabFolder() async throws {
        let dir = try TemporaryDirectory()
        _ = try ArchiveFixtures.makeArchive(["a.txt": "a"], format: "zip", in: dir, name: "a.zip")
        let model = makeModel(at: dir.url)
        await model.reload()

        #expect(await model.folderForNewTab(try item(named: "a.zip", in: model)) == nil)
    }

    @Test func plainFileIsNotATabFolder() async throws {
        let dir = try TemporaryDirectory()
        let file = try dir.file("notes.txt", contents: "x")
        let link = dir.url.appendingPathComponent("notesLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let model = makeModel(at: dir.url)
        await model.reload()

        #expect(await model.folderForNewTab(try item(named: "notes.txt", in: model)) == nil)
        #expect(await model.folderForNewTab(try item(named: "notesLink", in: model)) == nil)
    }

    @Test func folderInsideAnArchiveIsNotATabFolder() async throws {
        let dir = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(["img/x.png": "x", "a.txt": "a"], format: "zip", in: dir, name: "a.zip")
        let model = makeModel(at: dir.url)
        await model.navigate(to: zip)
        #expect(model.archiveLocation != nil)

        let folder = try item(named: "img", in: model)
        #expect(folder.isDirectory)
        #expect(await model.folderForNewTab(folder) == nil)
        #expect(await model.folderForNewTab(try item(named: "a.txt", in: model)) == nil)
    }

    @Test func classifyingDoesNotNavigate() async throws {
        let dir = try TemporaryDirectory()
        try dir.folder("Folder")
        let model = makeModel(at: dir.url)
        await model.reload()

        _ = await model.folderForNewTab(try item(named: "Folder", in: model))

        #expect(samePath(model.currentURL, dir.url))
        #expect(model.history.canGoBack == false)
    }

    /// The synchronous menu check: true exactly where `folderForNewTab` would answer a URL (outside archives).
    @Test func menuCheckMatchesTheClassification() async throws {
        let dir = try TemporaryDirectory()
        try dir.folder("Folder")
        let app = try dir.folder("Tool.app")
        try dir.folder("Tool.app/Contents")
        let file = try dir.file("notes.txt", contents: "x")
        _ = try ArchiveFixtures.makeArchive(["a.txt": "a"], format: "zip", in: dir, name: "a.zip")
        let fm = FileManager.default
        for (name, target) in [
            ("linkFolder", dir.url.appendingPathComponent("Folder")), ("linkApp", app),
            ("linkFile", file), ("linkZip", dir.url.appendingPathComponent("a.zip")),
        ] {
            try fm.createSymbolicLink(at: dir.url.appendingPathComponent(name), withDestinationURL: target)
        }
        try fm.createSymbolicLink(
            at: dir.url.appendingPathComponent("broken"), withDestinationURL: dir.url.appendingPathComponent("missing"))
        let model = makeModel(at: dir.url)
        await model.reload()

        for item in model.items {
            let expected = await model.folderForNewTab(item) != nil
            #expect(BrowserModel.mayOpenAsFolder(item) == expected, "\(item.name)")
        }
        #expect(BrowserModel.mayOpenAsFolder(try item(named: "linkFolder", in: model)))
        #expect(!BrowserModel.mayOpenAsFolder(try item(named: "linkFile", in: model)))
    }
}
