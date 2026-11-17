import Foundation
import Testing
@testable import MacCommanderCore

/// A temp folder with `dst/` and a fake `Trash/`, and a center with its own catalog; nothing touches the
/// real Trash or the shared catalog.
@MainActor
private struct ExtractFixture {
    let tmp: TemporaryDirectory
    let dst: URL
    let trashFolder: URL
    let catalog = ArchiveCatalog()
    let center: FileOperationCenter

    init() throws {
        tmp = try TemporaryDirectory()
        dst = try tmp.folder("dst")
        trashFolder = try tmp.folder("Trash")
        let trash = fakeTrash(into: trashFolder)
        center = FileOperationCenter(
            undo: FileUndoStack(trash: trash), trash: trash, allowClone: true, catalog: catalog)
    }

    /// Every name in `dst`, hidden ones included, sorted.
    var dstNames: [String] { names(in: dst) }

    func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
}

/// chmod 0755 on every folder below `root` (a sync helper: enumerators can't be iterated in async code).
private func makeFoldersWritable(_ root: URL) {
    let fm = FileManager.default
    guard let all = fm.enumerator(atPath: root.path) else { return }
    for case let path as String in all where all.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
    }
}

private let keepBoth: ConflictResolver = { _ in ConflictDecision(choice: .keepBoth, applyToAll: true) }
private let failOnConflict: ConflictResolver = { conflict in
    Issue.record("unexpected conflict for \(conflict.existing.lastPathComponent)")
    return ConflictDecision(choice: .stop, applyToAll: true)
}

@MainActor
struct ArchiveExtractorTests {
    private let imagesZip: [String: String] = ["img/a.png": "A", "img/b.png": "B", "c.txt": "C"]

    @Test func patternEscapesGlobCharacters() {
        #expect(ArchiveExtractor.pattern(for: "img/a.png") == "img/a.png")
        #expect(ArchiveExtractor.pattern(for: #"st*r [x]?\.txt"#) == #"st\*r \[x]\?\\.txt"#)
    }

    @Test func extractsSelectedEntryOnly() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)

        let result = try await f.center.extract(["img/a.png"], from: zip, into: f.dst, resolver: failOnConflict)

        #expect(result.outcome == .finished)
        #expect(f.dstNames == ["a.png"])
        #expect(f.contents(f.dst.appendingPathComponent("a.png")) == "A")
        #expect(result.completed.map(\.destination.lastPathComponent) == ["a.png"])
        #expect(f.center.operations.isEmpty)
    }

    @Test func extractsFolderEntryWithContents() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)

        _ = try await f.center.extract(["img"], from: zip, into: f.dst, resolver: failOnConflict)

        #expect(f.dstNames == ["img"])
        #expect(f.names(in: f.dst.appendingPathComponent("img")) == ["a.png", "b.png"])
        #expect(f.contents(f.dst.appendingPathComponent("img/b.png")) == "B")
    }

    @Test func globAndSpecialNames() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(
            ["st*r [x].txt": "star", "stXr x.txt": "X", "Ärger neu.md": "Ä"], format: "zip", in: f.tmp)

        _ = try await f.center.extract(["st*r [x].txt"], from: zip, into: f.dst, resolver: failOnConflict)
        #expect(f.dstNames == ["st*r [x].txt"])
        #expect(f.contents(f.dst.appendingPathComponent("st*r [x].txt")) == "star")

        _ = try await f.center.extract(["Ärger neu.md"], from: zip, into: f.dst, resolver: failOnConflict)
        #expect(f.dstNames.count == 2)
        #expect(f.contents(f.dst.appendingPathComponent("Ärger neu.md")) == "Ä")
    }

    @Test func missingOrEscapingEntryThrowsAndLeavesNothing() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)

        await #expect(throws: ArchiveError.unreadable(message: "“nope.txt” isn’t in the archive.")) {
            _ = try await f.center.extract(["img/a.png", "nope.txt"], from: zip, into: f.dst, resolver: failOnConflict)
        }
        for entry in ["nope.txt", "../c.txt", "img/../c.txt"] {
            await #expect(throws: ArchiveError.self) {
                _ = try await f.center.extract([entry], from: zip, into: f.dst, resolver: failOnConflict)
            }
        }
        #expect(f.dstNames.isEmpty)
        #expect(f.center.undo.records.isEmpty)
    }

    @Test func hostileEntriesStayInside() async throws {
        let f = try ExtractFixture()
        let outside = try f.tmp.folder("outside")
        try "keep".write(to: outside.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
        let tree = try f.tmp.folder("tree")
        let ok = try f.tmp.folder("tree/ok")
        for name in ["evil", "evil2", "abs"] {
            try name.write(to: ok.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(
            atPath: ok.appendingPathComponent("l").path, withDestinationPath: outside.path)
        let tree2 = try f.tmp.folder("tree2")
        try f.tmp.file("tree2/l/x", contents: "through the link")
        let archive = f.tmp.url.appendingPathComponent("hostile.tar")
        // ../evil lands next to dst's staging parent, ../../evil2 next to dst, /abs inside `outside`;
        // `l` is a symlink to `outside`, followed by `l/x`.
        try ArchiveFixtures.run("/usr/bin/bsdtar", [
            "-c", "-f", archive.path, "--format", "pax", "-P",
            "-s", ",^ok/evil$,../evil,", "-s", ",^ok/evil2$,../../evil2,",
            "-s", ",^ok/abs$,\(outside.path)/abs,", "-s", ",^ok/l$,l,",
            "-C", tree.path, "ok/evil", "ok/evil2", "ok/abs", "ok/l",
            "-C", tree2.path, "l/x",
        ])
        // The plants really are in the fixture.
        let listing = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/bsdtar"), ["-tf", archive.path, "-P"])
        let listed = Set(String(decoding: listing.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(listed == ["../evil", "../../evil2", "\(outside.path)/abs", "l", "l/x"])
        let rootBefore = f.names(in: f.tmp.url)

        // bsdtar refuses the hostile entries and exits non-zero.
        await #expect(throws: ArchiveError.self) {
            _ = try await f.center.extractAll(archive, into: f.dst, resolver: failOnConflict)
        }

        #expect(f.names(in: outside) == ["existing.txt"])
        #expect(f.contents(outside.appendingPathComponent("existing.txt")) == "keep")
        #expect(f.names(in: f.tmp.url) == rootBefore)
        #expect(!FileManager.default.fileExists(atPath: f.tmp.url.deletingLastPathComponent().appendingPathComponent("evil2").path))
        #expect(!f.dstNames.contains { $0.hasPrefix(".mc-partial-") })
    }

    @Test func encryptedZip() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeEncryptedZip(["a.txt": "secret text", "b.txt": "more"], password: "secret", in: f.tmp)

        await #expect(throws: ArchiveError.passwordRequired) {
            _ = try await f.center.extract(["a.txt"], from: zip, into: f.dst, resolver: failOnConflict)
        }
        #expect(f.dstNames.isEmpty)

        await f.catalog.setPassword("wrong", for: zip)
        await #expect(throws: ArchiveError.incorrectPassword) {
            _ = try await f.center.extractAll(zip, into: f.dst, resolver: failOnConflict)
        }
        #expect(f.dstNames.isEmpty)

        await f.catalog.setPassword("secret", for: zip)
        _ = try await f.center.extract(["a.txt"], from: zip, into: f.dst, resolver: failOnConflict)
        #expect(f.dstNames == ["a.txt"])
        #expect(f.contents(f.dst.appendingPathComponent("a.txt")) == "secret text")
    }

    @Test func conflictUsesResolver() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)
        try "mine".write(to: f.dst.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

        let result = try await f.center.extract(["c.txt"], from: zip, into: f.dst, resolver: keepBoth)

        #expect(result.completed.map(\.destination.lastPathComponent) == ["c 2.txt"])
        #expect(f.dstNames == ["c 2.txt", "c.txt"])
        #expect(f.contents(f.dst.appendingPathComponent("c.txt")) == "mine")
        #expect(f.contents(f.dst.appendingPathComponent("c 2.txt")) == "C")
        #expect(f.center.undo.undoTitle == "Extract")
        guard case .transferred(.copy, let items, let replaced) = f.center.undo.records.last?.action else {
            Issue.record("expected a copy record")
            return
        }
        #expect(items.map(\.destination.lastPathComponent) == ["c 2.txt"])
        #expect(replaced.isEmpty)

        _ = try await f.center.performUndo()
        #expect(f.dstNames == ["c.txt"])
        #expect(f.names(in: f.trashFolder) == ["c 2.txt"])
    }

    @Test func replaceIsUndoneByRestoringTheOriginal() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)
        let mine = f.dst.appendingPathComponent("c.txt")
        try "mine".write(to: mine, atomically: true, encoding: .utf8)

        _ = try await f.center.extract(["c.txt"], from: zip, into: f.dst) { _ in
            ConflictDecision(choice: .replace, applyToAll: true)
        }
        #expect(f.contents(mine) == "C")
        #expect(f.center.undo.undoTitle == "Extract")

        _ = try await f.center.performUndo()
        #expect(f.dstNames == ["c.txt"])
        #expect(f.contents(mine) == "mine")
    }

    @Test func duplicateAndNestedEntriesAreMovedOnce() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)

        let result = try await f.center.extract(
            ["c.txt", "img/a.png", "img", "c.txt", "img/b.png"], from: zip, into: f.dst, resolver: failOnConflict)

        #expect(result.outcome == .finished)
        #expect(result.completed.map(\.destination.lastPathComponent) == ["c.txt", "img"])
        #expect(f.names(in: f.dst.appendingPathComponent("img")) == ["a.png", "b.png"])
    }

    /// bsdtar restores `r-x` folders; a folder without write permission can't be moved to a new parent or
    /// emptied, so staging makes its folders owner-writable.
    @Test func readOnlyFoldersExtractAndLeaveNoStaging() async throws {
        let f = try ExtractFixture()
        let src = try f.tmp.folder("ro-src")
        try f.tmp.file("ro-src/ro/f.txt", contents: "F")
        try f.tmp.file("ro-src/ro/sub/g.txt", contents: "G")
        try f.tmp.file("ro-src/c.txt", contents: "C")
        let fm = FileManager.default
        let readOnly = [src.appendingPathComponent("ro/sub"), src.appendingPathComponent("ro")]
        for folder in readOnly { try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        let tree = f.tmp.url
        defer {
            // Let TemporaryDirectory clean up whatever is left.
            makeFoldersWritable(tree)
            for folder in readOnly { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        }
        let onlyRo = f.tmp.url.appendingPathComponent("onlyro.tar")
        try ArchiveFixtures.run("/usr/bin/bsdtar", ["-c", "-f", onlyRo.path, "-C", src.path, "ro"])
        let mixed = f.tmp.url.appendingPathComponent("mixed.tar")
        try ArchiveFixtures.run("/usr/bin/bsdtar", ["-c", "-f", mixed.path, "-C", src.path, "ro", "c.txt"])

        // One top-level read-only folder, moved as is.
        let all = try await f.center.extractAll(onlyRo, into: f.dst, resolver: failOnConflict)
        #expect(all.outcome == .finished)
        #expect(f.contents(f.dst.appendingPathComponent("ro/sub/g.txt")) == "G")
        // Several items: the read-only folder is moved into the wrapper folder first.
        let wrapped = try await f.center.extractAll(mixed, into: f.dst, resolver: failOnConflict)
        #expect(wrapped.outcome == .finished)
        #expect(f.contents(f.dst.appendingPathComponent("mixed/ro/f.txt")) == "F")
        // An entry inside a read-only folder.
        let one = try await f.center.extract(["ro/f.txt"], from: mixed, into: f.dst, resolver: failOnConflict)
        #expect(one.outcome == .finished)
        #expect(f.contents(f.dst.appendingPathComponent("f.txt")) == "F")
        // Skip leaves the staged copy behind; it must still be removed.
        let skipped = try await f.center.extract(["ro"], from: mixed, into: f.dst) { _ in
            ConflictDecision(choice: .skip, applyToAll: true)
        }
        #expect(skipped.skipped.count == 1)
        #expect(f.dstNames == ["f.txt", "mixed", "ro"])
    }

    @Test func extractAllSingleVsMultiple() async throws {
        let f = try ExtractFixture()
        let single = try ArchiveFixtures.makeArchive(
            ["assets/a.txt": "A", "assets/sub/b.txt": "B"], format: "zip", in: f.tmp, name: "pack.zip")
        let loose = try ArchiveFixtures.makeArchive(
            ["a.txt": "A", "b.txt": "B"], format: "tgz", in: f.tmp, name: "x.tar.gz")

        let first = try await f.center.extractAll(single, into: f.dst, resolver: failOnConflict)
        #expect(first.completed.map(\.destination.path) == [f.dst.appendingPathComponent("assets").path])
        #expect(f.contents(f.dst.appendingPathComponent("assets/sub/b.txt")) == "B")

        let second = try await f.center.extractAll(loose, into: f.dst, resolver: failOnConflict)
        #expect(second.completed.map(\.destination.lastPathComponent) == ["x"])
        #expect(f.names(in: f.dst.appendingPathComponent("x")) == ["a.txt", "b.txt"])

        let third = try await f.center.extractAll(loose, into: f.dst, resolver: failOnConflict)
        #expect(third.completed.map(\.destination.lastPathComponent) == ["x 2"])
        #expect(f.names(in: f.dst.appendingPathComponent("x 2")) == ["a.txt", "b.txt"])
        #expect(f.dstNames == ["assets", "x", "x 2"])
        #expect(f.center.undo.records.count == 3)
    }

    @Test func cancelRemovesStaging() async throws {
        let f = try ExtractFixture()
        let src = try f.tmp.folder("big")
        let random = try #require(FileHandle(forReadingAtPath: "/dev/urandom"))
        for index in 0..<3 {
            try random.readData(ofLength: 10_000_000).write(to: src.appendingPathComponent("r\(index).bin"))
        }
        let archive = f.tmp.url.appendingPathComponent("big.tgz")
        try ArchiveFixtures.run("/usr/bin/bsdtar", ["-c", "-z", "-f", archive.path, "-C", src.path, "."])

        let center = f.center
        let dst = f.dst
        let task = Task { @MainActor in
            try await center.extractAll(archive, into: dst, resolver: failOnConflict)
        }
        // Cancel as soon as the staging folder exists, i.e. while bsdtar is starting or running.
        let deadline = ContinuousClock.now + .seconds(5)
        while !f.dstNames.contains(where: { $0.hasPrefix(".mc-partial-") }) {
            guard ContinuousClock.now < deadline else {
                Issue.record("staging never appeared")
                task.cancel()
                return
            }
            try await Task.sleep(for: .microseconds(200))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(f.dstNames.isEmpty)
        #expect(center.operations.isEmpty)
        #expect(center.undo.records.isEmpty)
    }

    @Test func destinationInsideArchiveIsRefused() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)
        let inside = ArchivePath.url(archive: zip, inner: "img")

        await #expect(throws: CocoaError.self) {
            _ = try await f.center.extract(["c.txt"], from: zip, into: inside, resolver: failOnConflict)
        }
        await #expect(throws: CocoaError.self) {
            _ = try await f.center.extractAll(zip, into: inside, resolver: failOnConflict)
        }
        #expect(f.center.operations.isEmpty)
    }

    // MARK: Single entry to a promised URL (drag to Finder)

    @Test func extractsSingleEntryToPromisedName() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)
        let target = f.dst.appendingPathComponent("promised.png")

        try await ArchiveExtractor.extract("img/a.png", from: zip, to: target, password: nil)

        #expect(f.dstNames == ["promised.png"])
        #expect(f.contents(target) == "A")
    }

    @Test func extractsSingleFolderEntryToPromisedName() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)
        let target = f.dst.appendingPathComponent("img")

        try await ArchiveExtractor.extract("img", from: zip, to: target, password: nil)

        #expect(f.dstNames == ["img"])
        #expect(f.names(in: target) == ["a.png", "b.png"])
    }

    @Test func singleEntryExtractionNeverOverwrites() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)
        let target = try f.tmp.file("dst/a.png", contents: "existing")

        await #expect(throws: CocoaError.self) {
            try await ArchiveExtractor.extract("img/a.png", from: zip, to: target, password: nil)
        }
        #expect(f.dstNames == ["a.png"])
        #expect(f.contents(target) == "existing")
    }

    @Test func singleEntryExtractionRemovesStagingOnFailure() async throws {
        let f = try ExtractFixture()
        let zip = try ArchiveFixtures.makeArchive(imagesZip, format: "zip", in: f.tmp)

        await #expect(throws: ArchiveError.self) {
            try await ArchiveExtractor.extract("missing.txt", from: zip, to: f.dst.appendingPathComponent("x"), password: nil)
        }
        #expect(f.dstNames.isEmpty)
    }

    @Test func baseNameDropsArchiveExtension() {
        func base(_ name: String) -> String { ArchiveFormats.baseName(of: URL(fileURLWithPath: "/t/\(name)")) }
        #expect(base("assets.tar.gz") == "assets")
        #expect(base("x.TGZ") == "x")
        #expect(base("a.b.zip") == "a.b")
        #expect(base("doc.docx") == "doc")
        #expect(base("plain.dat") == "plain")
    }
}
