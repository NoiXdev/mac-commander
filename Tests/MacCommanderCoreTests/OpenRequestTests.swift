import Foundation
import Testing
@testable import MacCommanderCore

@Suite struct OpenRequestTests {
    private func u(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func singleFolderOpensItself() {
        let result = OpenRequest.requests(for: [u("/a/Projects")]) { _ in true }
        #expect(result == [OpenRequest(folder: u("/a/Projects"), selection: [])])
    }

    @Test func filesGroupByParentInOrder() {
        let result = OpenRequest.requests(for: [u("/a/x.txt"), u("/b/y.txt"), u("/a/z.txt")]) { _ in false }
        #expect(result == [
            OpenRequest(folder: u("/a"), selection: [u("/a/x.txt"), u("/a/z.txt")]),
            OpenRequest(folder: u("/b"), selection: [u("/b/y.txt")]),
        ])
    }

    @Test func folderAmongOthersIsSelected() {
        let result = OpenRequest.requests(for: [u("/a/Projects"), u("/a/x.txt")]) { $0.lastPathComponent == "Projects" }
        #expect(result == [OpenRequest(folder: u("/a"), selection: [u("/a/Projects"), u("/a/x.txt")])])
    }

    @Test func packageIsSelectedInParent() {
        let result = OpenRequest.requests(for: [u("/Applications/Safari.app")]) { _ in false }
        #expect(result == [OpenRequest(folder: u("/Applications"), selection: [u("/Applications/Safari.app")])])
    }

    @Test func missingPathIsTreatedAsFile() {
        let result = OpenRequest.requests(for: [u("/nope/gone.txt")]) { _ in false }
        #expect(result == [OpenRequest(folder: u("/nope"), selection: [u("/nope/gone.txt")])])
    }

    @Test func nonFileURLsDropped() throws {
        let web = try #require(URL(string: "https://example.com"))
        #expect(OpenRequest.requests(for: [web]) { _ in true }.isEmpty)
    }

    @Test func folderCheckRealDisk() throws {
        let dir = try TemporaryDirectory()
        let folder = try dir.folder("f")
        let file = try dir.file("a.txt")
        let package = try dir.folder("X.app")
        #expect(OpenRequest.folderCheck(folder))
        #expect(!OpenRequest.folderCheck(file))
        #expect(!OpenRequest.folderCheck(package))
    }

    @Test func folderCheckFollowsSymlinks() throws {
        let dir = try TemporaryDirectory()
        let folder = try dir.folder("f")
        let file = try dir.file("a.txt")
        let folderLink = dir.url.appendingPathComponent("folder-link")
        let fileLink = dir.url.appendingPathComponent("file-link")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)
        #expect(OpenRequest.folderCheck(folderLink))
        #expect(!OpenRequest.folderCheck(fileLink))
        // The request keeps the path as given, not the resolved one.
        let result = OpenRequest.requests(for: [folderLink], isFolder: OpenRequest.folderCheck)
        #expect(result == [OpenRequest(folder: folderLink.standardizedFileURL, selection: [])])
    }

    /// `/tmp`, `/var` and `/etc` link into `/private`, which `resolvingSymlinksInPath()` strips again.
    @Test func folderCheckFollowsPrivateSymlinks() {
        for path in ["/tmp", "/var", "/etc"] {
            #expect(OpenRequest.folderCheck(URL(fileURLWithPath: path)), "\(path)")
        }
    }
}
