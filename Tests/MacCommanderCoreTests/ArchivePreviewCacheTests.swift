import Foundation
import Testing
@testable import MacCommanderCore

/// Each test uses its own cache root inside a temporary folder; the shared cache is never touched.
@Suite(.english) struct ArchivePreviewCacheTests {
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

    @Test func refusesSymlinkEntries() async throws {
        let temp = try TemporaryDirectory()
        let outside = try temp.file("outside.txt", contents: "private")
        let zip = try ArchiveFixtures.makeArchive(
            ["notes.txt": "→" + outside.path, "c.txt": "C"], format: "zip", in: temp)
        let root = temp.url.appendingPathComponent("Previews", isDirectory: true)
        let cache = ArchivePreviewCache(root: root, catalog: ArchiveCatalog())
        // The list marks the entry, so the UI skips it before extracting.
        let listed = try await ArchiveCatalog().items(in: "", of: zip, includeHidden: false)
        #expect(listed.first { $0.name == "notes.txt" }?.isSymlink == true)
        #expect(listed.first { $0.name == "c.txt" }?.isSymlink == false)

        await #expect(throws: ArchiveError.unreadable(message: "It’s a link.")) {
            _ = try await cache.files(["notes.txt"], of: zip)
        }
        await #expect(throws: ArchiveError.unreadable(message: "It’s a link.")) {
            _ = try await cache.files(["c.txt", "notes.txt"], of: zip)
        }
        // Nothing of the refused runs is left; ordinary entries still work.
        #expect(contents(try await cache.files(["c.txt"], of: zip)) == ["C"])
        #expect(try String(contentsOf: outside, encoding: .utf8) == "private")
    }

    @Test func extractedFilesAreReadOnly() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(files, format: "zip", in: temp)
        let root = temp.url.appendingPathComponent("Previews", isDirectory: true)
        let cache = ArchivePreviewCache(root: root, catalog: ArchiveCatalog())
        let file = try await cache.files(["img/a.png"], of: zip)[0]

        let mode = try #require(
            try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber).intValue
        #expect(mode & 0o222 == 0)
        #expect(!FileManager.default.isWritableFile(atPath: file.path))
        await cache.purge()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// Apps save duplicates of a locked file next to it, and Archive Utility expands a nested archive
    /// beside itself; the cache is purged permanently, so its staging folders must not accept new items.
    @Test func stagingFoldersAreReadOnlyAndStillPurged() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(files, format: "zip", in: temp)
        let root = temp.url.appendingPathComponent("Previews", isDirectory: true)
        let cache = ArchivePreviewCache(root: root, catalog: ArchiveCatalog())
        let extracted = try await cache.files(["img/a.png", "c.txt"], of: zip)

        // `.mc-partial-<UUID>/img/a.png` and `.mc-partial-<UUID>/c.txt`: both folders refuse new items.
        let nested = extracted[0].deletingLastPathComponent()
        let staging = extracted[1].deletingLastPathComponent()
        #expect(nested.deletingLastPathComponent() == staging)
        for folder in [staging, nested] {
            let mode = try #require(
                try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
            ).intValue
            #expect(mode & 0o222 == 0)
            #expect(!FileManager.default.isWritableFile(atPath: folder.path))
            #expect(throws: (any Error).self) {
                try "copy".write(to: folder.appendingPathComponent("a copy.png"), atomically: false, encoding: .utf8)
            }
        }
        // The version folder stays writable for later runs.
        #expect(contents(try await cache.files(["img/b.png"], of: zip)) == ["B"])

        await cache.purge()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// A temp cleaner or another instance's purge removed the version folder: start a fresh version.
    @Test func missingVersionFolderStartsFresh() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(files, format: "zip", in: temp)
        let root = temp.url.appendingPathComponent("Previews", isDirectory: true)
        let cache = ArchivePreviewCache(root: root, catalog: ArchiveCatalog())
        _ = try await cache.files(["c.txt"], of: zip)
        // Like another instance's `purge`.
        await ArchivePreviewCache(root: root, catalog: ArchiveCatalog()).purge()
        #expect(!FileManager.default.fileExists(atPath: root.path))

        #expect(contents(try await cache.files(["img/a.png", "c.txt"], of: zip)) == ["A", "C"])
        #expect(versions(in: root).count == 1)
    }

    /// An entry stored with mode 000 is made owner-readable, so Quick Look can show it.
    @Test func unreadableEntriesBecomeReadable() async throws {
        let temp = try TemporaryDirectory()
        let real = try temp.file("real.txt", contents: "locked")
        let spec = try temp.file("spec.mtree", contents: "#mtree\nlocked.txt type=file mode=0000 contents=\(real.path)\n")
        let tar = temp.url.appendingPathComponent("locked.tar")
        try ArchiveFixtures.run("/usr/bin/bsdtar", ["-c", "-f", tar.path, "--format", "ustar", "@" + spec.path])
        let cache = ArchivePreviewCache(
            root: temp.url.appendingPathComponent("Previews", isDirectory: true), catalog: ArchiveCatalog())

        let file = try await cache.files(["locked.txt"], of: tar)[0]
        #expect(contents([file]) == ["locked"])
        #expect(!FileManager.default.isWritableFile(atPath: file.path))
        await cache.purge()
    }

    @Test func missingEntryNamesLastComponent() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(files, format: "zip", in: temp)
        let cache = ArchivePreviewCache(
            root: temp.url.appendingPathComponent("Previews", isDirectory: true), catalog: ArchiveCatalog())
        await #expect(throws: ArchiveError.unreadable(message: "“nope.png” isn’t in the archive.")) {
            _ = try await cache.files(["img/nope.png"], of: zip)
        }
        await cache.purge()
    }
}
