import Foundation
import Testing
@testable import MacCommanderCore

struct ArchivePathTests {
    private func makeFile(_ tmp: TemporaryDirectory, _ name: String) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func splitFindsArchiveRootAndInner() throws {
        let tmp = try TemporaryDirectory()
        let zip = try makeFile(tmp, "a.zip")
        let root = try #require(ArchivePath.split(zip))
        #expect(root.archive.path == zip.standardizedFileURL.path)
        #expect(root.inner == "")
        let deep = try #require(ArchivePath.split(zip.appendingPathComponent("img/x")))
        #expect(deep.archive.path == zip.standardizedFileURL.path)
        #expect(deep.inner == "img/x")
        // Trailing slash / isDirectory flag don't matter.
        let slash = try #require(ArchivePath.split(URL(fileURLWithPath: zip.path + "/img/", isDirectory: true)))
        #expect(slash.inner == "img")
    }

    @Test func splitIgnoresOrdinaryFolders() throws {
        let tmp = try TemporaryDirectory()
        let sub = try tmp.folder("folder/sub")
        #expect(ArchivePath.split(sub) == nil)
        #expect(ArchivePath.split(tmp.url.appendingPathComponent("missing/x")) == nil)
    }

    @Test func splitThroughSymlinkedFolder() throws {
        let tmp = try TemporaryDirectory()
        let folder = try tmp.folder("real")
        let link = tmp.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(ArchivePath.split(link) == nil)
        #expect(ArchivePath.split(link.appendingPathComponent("sub")) == nil)
        // A symlink to a file is an archive.
        let zip = try makeFile(tmp, "b.zip")
        let zipLink = tmp.url.appendingPathComponent("zl")
        try FileManager.default.createSymbolicLink(at: zipLink, withDestinationURL: zip)
        let location = try #require(ArchivePath.split(zipLink.appendingPathComponent("d")))
        #expect(location.archive.path == zipLink.standardizedFileURL.path)
        #expect(location.inner == "d")
    }

    @Test func urlRoundTrips() throws {
        let tmp = try TemporaryDirectory()
        let zip = try makeFile(tmp, "a.zip")
        #expect(ArchivePath.url(archive: zip, inner: "").path == zip.path)
        let url = ArchivePath.url(archive: zip, inner: "img/x y.png")
        #expect(url.path == zip.path + "/img/x y.png")
        let location = try #require(ArchivePath.split(url))
        #expect(location.inner == "img/x y.png")
        #expect(location.archive.path == zip.standardizedFileURL.path)
    }

    @Test func nearestAncestorSkipsFiles() throws {
        let tmp = try TemporaryDirectory()
        let file = try makeFile(tmp, "file.txt")
        let result = PathUtilities.nearestExistingAncestor(of: file.appendingPathComponent("x"))
        #expect(result.path == tmp.url.standardizedFileURL.path)
        #expect(PathUtilities.nearestExistingAncestor(of: file).path == tmp.url.standardizedFileURL.path)
    }
}
