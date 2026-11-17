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

    @Test func topLevelDropsDescendantsOfOtherURLs() {
        func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
        let urls = [url("/a/F"), url("/a/F/x"), url("/a/F/sub/y"), url("/a/Fx"), url("/a/b.txt"), url("/a/Fx/../F/z")]
        // Order is kept; a sibling sharing a name prefix ("Fx") is not inside "F"; paths are standardized.
        #expect(PathUtilities.topLevel(urls).map(\.path) == ["/a/F", "/a/Fx", "/a/b.txt"])
        #expect(PathUtilities.topLevel([url("/a/F/x"), url("/a/F")]).map(\.path) == ["/a/F"])
        #expect(PathUtilities.topLevel([]).isEmpty)
    }
}
