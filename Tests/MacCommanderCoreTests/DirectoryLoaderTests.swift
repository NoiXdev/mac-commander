import Foundation
import Testing
@testable import MacCommanderCore

struct DirectoryLoaderTests {
    let loader = DirectoryLoader()

    @Test func listsFilesAndFolders() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("a.txt", contents: "abc")
        try dir.folder("sub")
        let items = try await loader.contents(of: dir.url, includeHidden: false)
        #expect(items.count == 2)
        let file = try #require(items.first { $0.name == "a.txt" })
        #expect(file.size == 3)
        #expect(!file.isDirectory)
        let sub = try #require(items.first { $0.name == "sub" })
        #expect(sub.isDirectory)
        #expect(sub.size == nil)
    }

    @Test func hidesDotFilesUnlessRequested() async throws {
        let dir = try TemporaryDirectory()
        try dir.file(".secret")
        try dir.file("visible")
        let hidden = try await loader.contents(of: dir.url, includeHidden: false)
        #expect(!hidden.contains { $0.name == ".secret" })
        let all = try await loader.contents(of: dir.url, includeHidden: true)
        #expect(all.contains { $0.name == ".secret" })
    }

    @Test func treatsAppBundleAsFile() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("X.app/Contents/Info.plist", contents: "<plist/>")
        let items = try await loader.contents(of: dir.url, includeHidden: false)
        let app = try #require(items.first)
        #expect(app.isPackage)
        #expect(!app.isDirectory)
    }

    @Test func permissionDeniedIsMapped() async throws {
        let dir = try TemporaryDirectory()
        let locked = try dir.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        await #expect(throws: DirectoryLoadError.permissionDenied(locked)) {
            try await loader.contents(of: locked, includeHidden: false)
        }
    }

    @Test func missingFolderIsNotFound() async throws {
        let dir = try TemporaryDirectory()
        let missing = dir.url.appendingPathComponent("nope", isDirectory: true)
        await #expect(throws: DirectoryLoadError.notFound(missing)) {
            try await loader.contents(of: missing, includeHidden: false)
        }
    }

    @Test func loadsTenThousandItemsQuickly() async throws {
        let dir = try TemporaryDirectory()
        for i in 0..<10_000 {
            FileManager.default.createFile(atPath: dir.url.appendingPathComponent("f\(i)").path, contents: nil)
        }
        let clock = ContinuousClock()
        var items: [FileItem] = []
        let elapsed = try await clock.measure {
            items = try await loader.contents(of: dir.url, includeHidden: false)
        }
        #expect(items.count == 10_000)
        #expect(elapsed < .seconds(3))
    }
}

extension DirectoryLoaderTests {
    @Test func fileIsNotADirectory() async throws {
        let dir = try TemporaryDirectory()
        let file = try dir.file("a.txt")
        await #expect(throws: DirectoryLoadError.notADirectory(file)) {
            try await loader.contents(of: file, includeHidden: false)
        }
    }
}
