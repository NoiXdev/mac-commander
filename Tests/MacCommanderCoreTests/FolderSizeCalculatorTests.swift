import Foundation
import Synchronization
import Testing

@testable import MacCommanderCore

struct FolderSizeCalculatorTests {
    @Test func sumsFilesRecursively() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("a.txt", contents: "abc")
        try tmp.file("dir/b.txt", contents: "12345")
        let size = try await FolderSizeCalculator.size(of: tmp.url)
        #expect(size == FolderSize(bytes: 8, items: 3))
    }

    @Test func doesNotFollowSymlinks() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("a.txt", contents: "abc")
        try tmp.file("dir/b.txt", contents: "12345")
        try FileManager.default.createSymbolicLink(
            at: tmp.url.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/usr"))
        let size = try await FolderSizeCalculator.size(of: tmp.url)
        #expect(size == FolderSize(bytes: 8, items: 4))
    }

    @Test func cancellationInsideTheLoopThrows() async throws {
        let tmp = try TemporaryDirectory()
        let root = tmp.url
        for i in 0..<2_000 {
            FileManager.default.createFile(atPath: root.appendingPathComponent("f\(i)").path, contents: nil)
        }
        let seen = Mutex(0)
        let task = Task {
            try await FolderSizeCalculator.size(of: root) { count in
                seen.withLock { $0 = count }
                // Cancel the calculator's own task once about 100 items were seen.
                if count == 100 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(seen.withLock { $0 } < 2_000)
    }

    @Test func countsHiddenFilesAndPackageContents() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file(".hidden", contents: "ab")
        try tmp.file("X.app/Contents/f", contents: "123")
        // .hidden, X.app, X.app/Contents, X.app/Contents/f
        #expect(try await FolderSizeCalculator.size(of: tmp.url) == FolderSize(bytes: 5, items: 4))
    }

    @Test func followsARootSymlinkButNothingInside() async throws {
        let tmp = try TemporaryDirectory()
        let target = try tmp.folder("target")
        try tmp.file("target/a.txt", contents: "abc")
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("inner"), withDestinationURL: URL(fileURLWithPath: "/usr"))
        let link = tmp.url.appendingPathComponent("rootlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try await FolderSizeCalculator.size(of: link) == FolderSize(bytes: 3, items: 2))
    }

    @Test func skipsAnUnreadableSubfolder() async throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("a.txt", contents: "abc")
        let locked = try tmp.folder("locked")
        try tmp.file("locked/secret", contents: "zzzz")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        // a.txt and locked itself
        #expect(try await FolderSizeCalculator.size(of: tmp.url) == FolderSize(bytes: 3, items: 2))
    }

    @Test func unreadableRootThrowsNotCancellation() async throws {
        let tmp = try TemporaryDirectory()
        let locked = try tmp.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        do {
            _ = try await FolderSizeCalculator.size(of: locked)
            Issue.record("expected an error")
        } catch {
            #expect(!(error is CancellationError))
        }
    }

    @Test func emptyFolderIsZero() async throws {
        let tmp = try TemporaryDirectory()
        #expect(try await FolderSizeCalculator.size(of: tmp.url) == FolderSize(bytes: 0, items: 0))
    }
}
