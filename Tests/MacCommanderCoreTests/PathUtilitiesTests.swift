import Foundation
import Testing
@testable import MacCommanderCore

struct PathUtilitiesTests {
    private func real(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @Test func nearestAncestorSkipsDeletedFolders() throws {
        let tmp = try TemporaryDirectory()
        let a = try tmp.folder("a")
        let c = try tmp.folder("a/b/c")
        try FileManager.default.removeItem(at: a.appendingPathComponent("b"))
        let result = PathUtilities.nearestExistingAncestor(of: c)
        #expect(real(result) == real(a))
    }

    @Test func nearestAncestorOfExistingFolderIsItself() throws {
        let tmp = try TemporaryDirectory()
        let a = try tmp.folder("a")
        #expect(real(PathUtilities.nearestExistingAncestor(of: a)) == real(a))
    }

    @Test func nearestAncestorOfRootIsRoot() {
        let root = URL(fileURLWithPath: "/")
        #expect(PathUtilities.nearestExistingAncestor(of: root).path == "/")
    }

    @Test func segmentsOfPath() {
        let url = URL(fileURLWithPath: "/Users/d/Docs")
        #expect(PathUtilities.segments(of: url).map(\.path) == ["/", "/Users", "/Users/d", "/Users/d/Docs"])
        #expect(PathUtilities.segments(of: URL(fileURLWithPath: "/")).map { $0.path } == ["/"])
    }
}
