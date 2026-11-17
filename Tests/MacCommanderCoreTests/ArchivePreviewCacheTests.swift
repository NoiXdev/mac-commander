import Foundation
import Testing
@testable import MacCommanderCore

/// Each test uses its own cache root inside a temporary folder; the shared cache is never touched.
struct ArchivePreviewCacheTests {
    private let files: [String: String] = ["img/a.png": "A", "img/b.png": "B", "c.txt": "C"]

    private func contents(_ urls: [URL]) -> [String?] {
        urls.map { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The version folders below `root`.
    private func versions(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    @Test func extractsOnceAndReuses() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(files, format: "zip", in: temp)
        let root = temp.url.appendingPathComponent("Previews", isDirectory: true)
        let cache = ArchivePreviewCache(root: root, catalog: ArchiveCatalog())

        let first = try await cache.files(["img/a.png"], of: zip)
        #expect(contents(first) == ["A"])
        #expect(first[0].path.hasPrefix(root.path + "/"))
        #expect(await cache.runCount == 1)

        let second = try await cache.files(["img/a.png"], of: zip)
        #expect(second == first)
        #expect(await cache.runCount == 1)

        // Only the missing entry is extracted.
        let both = try await cache.files(["img/a.png", "c.txt"], of: zip)
        #expect(both[0] == first[0])
        #expect(contents(both) == ["A", "C"])
        #expect(await cache.runCount == 2)
        #expect(versions(in: root).count == 1)
    }

    @Test func reextractsAfterArchiveChanged() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(files, format: "zip", in: temp, name: "p.zip")
        let root = temp.url.appendingPathComponent("Previews", isDirectory: true)
        let cache = ArchivePreviewCache(root: root, catalog: ArchiveCatalog())

        let old = try await cache.files(["c.txt"], of: zip)
        #expect(contents(old) == ["C"])
        let oldVersions = versions(in: root)

        try FileManager.default.removeItem(at: zip)
        _ = try ArchiveFixtures.makeArchive(["c.txt": "changed"], format: "zip", in: temp, name: "p.zip")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: zip.path)

        let new = try await cache.files(["c.txt"], of: zip)
        #expect(contents(new) == ["changed"])
        #expect(await cache.runCount == 2)
        // The old version folder is gone; one new one is left.
        let newVersions = versions(in: root)
        #expect(newVersions.count == 1)
        #expect(newVersions != oldVersions)
        #expect(!FileManager.default.fileExists(atPath: old[0].path))
    }

    @Test func orderMatchesRequest() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(files, format: "zip", in: temp)
        let cache = ArchivePreviewCache(
            root: temp.url.appendingPathComponent("Previews", isDirectory: true), catalog: ArchiveCatalog())

        #expect(contents(try await cache.files(["c.txt", "img/b.png", "img/a.png"], of: zip)) == ["C", "B", "A"])
        // Mixed: some entries cached, some new, duplicates kept in place.
        let fresh = ArchivePreviewCache(
            root: temp.url.appendingPathComponent("Previews2", isDirectory: true), catalog: ArchiveCatalog())
        _ = try await fresh.files(["img/b.png"], of: zip)
        let mixed = try await fresh.files(["c.txt", "img/b.png", "img/a.png", "c.txt"], of: zip)
        #expect(contents(mixed) == ["C", "B", "A", "C"])
        #expect(mixed.map(\.lastPathComponent) == ["c.txt", "b.png", "a.png", "c.txt"])
        #expect(await fresh.runCount == 2)
    }

    @Test func purgeRemovesRoot() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(files, format: "zip", in: temp)
        let root = temp.url.appendingPathComponent("Previews", isDirectory: true)
        let cache = ArchivePreviewCache(root: root, catalog: ArchiveCatalog())
        _ = try await cache.files(["img/a.png", "c.txt"], of: zip)
        #expect(FileManager.default.fileExists(atPath: root.path))

        await cache.purge()
        #expect(!FileManager.default.fileExists(atPath: root.path))

        // The cache forgot its entries: the next request extracts again.
        #expect(contents(try await cache.files(["c.txt"], of: zip)) == ["C"])
        #expect(await cache.runCount == 2)
    }

    @Test func missingEntryThrowsAndPasswordComesFromCatalog() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(files, format: "zip", in: temp)
        let cache = ArchivePreviewCache(
            root: temp.url.appendingPathComponent("Previews", isDirectory: true), catalog: ArchiveCatalog())
        await #expect(throws: ArchiveError.unreadable(message: "“nope.txt” isn’t in the archive.")) {
            _ = try await cache.files(["nope.txt"], of: zip)
        }

        let catalog = ArchiveCatalog()
        let encrypted = try ArchiveFixtures.makeEncryptedZip(["s.txt": "secret"], password: "pw", in: temp)
        let locked = ArchivePreviewCache(
            root: temp.url.appendingPathComponent("Locked", isDirectory: true), catalog: catalog)
        await #expect(throws: ArchiveError.passwordRequired) {
            _ = try await locked.files(["s.txt"], of: encrypted)
        }
        await catalog.setPassword("pw", for: encrypted)
        #expect(contents(try await locked.files(["s.txt"], of: encrypted)) == ["secret"])
    }
}
