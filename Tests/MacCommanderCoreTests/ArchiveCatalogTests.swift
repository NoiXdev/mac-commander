import Foundation
import Testing
@testable import MacCommanderCore

struct ArchiveCatalogTests {
    private static let tree: [String: String] = [
        "a.txt": "aaa",
        "sub/b.md": "bb",
        "sub/deep/c.txt": "c",
        "sub/link": "→b.md",
    ]

    private func listing(_ items: [FileItem]) -> [String] {
        items.map { "\($0.name)|\($0.isDirectory)|\($0.size.map(String.init) ?? "-")" }.sorted()
    }

    /// Runs `body`, failing (instead of hanging) if it takes longer than `seconds`.
    private func withTimeout<T: Sendable>(
        _ seconds: Int, _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test func listsZipAndTgz() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(Self.tree, format: "zip", in: temp)
        let tgz = try ArchiveFixtures.makeArchive(Self.tree, format: "tgz", in: temp)
        let catalog = ArchiveCatalog()
        let zipRoot = try await catalog.items(in: "", of: zip, includeHidden: false)
        let tgzRoot = try await catalog.items(in: "", of: tgz, includeHidden: false)
        #expect(listing(zipRoot) == ["a.txt|false|3", "sub|true|-"])
        #expect(listing(zipRoot) == listing(tgzRoot))
        let zipSub = try await catalog.items(in: "sub", of: zip, includeHidden: false)
        let tgzSub = try await catalog.items(in: "sub", of: tgz, includeHidden: false)
        // Symlinks are listed as files (size as the archive reports it, 0 for bsdtar zips).
        #expect(listing(zipSub) == ["b.md|false|2", "deep|true|-", "link|false|0"])
        #expect(listing(zipSub) == listing(tgzSub))
        let folder = try #require(zipRoot.first { $0.name == "sub" })
        #expect(folder.kind == "Folder")
        #expect(folder.url == zip.appendingPathComponent("sub"))
        let file = try #require(zipSub.first { $0.name == "b.md" })
        #expect(file.url == zip.appendingPathComponent("sub").appendingPathComponent("b.md"))
        #expect(file.dateModified != nil)
        #expect(!file.isPackage)
    }

    @Test func hiddenAndMacosxFiltered() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(
            ["a.txt": "a", ".DS_Store": "x", "__MACOSX/x": "x", "__MACOSX/sub/y": "x"],
            format: "zip", in: temp)
        let catalog = ArchiveCatalog()
        let visible = try await catalog.items(in: "", of: zip, includeHidden: false)
        #expect(visible.map(\.name) == ["a.txt"])
        let all = try await catalog.items(in: "", of: zip, includeHidden: true)
        #expect(all.map(\.name).sorted() == [".DS_Store", "__MACOSX", "a.txt"])
        #expect(all.first { $0.name == "__MACOSX" }?.isHidden == true)
        #expect(try await catalog.items(in: "__MACOSX", of: zip, includeHidden: false).isEmpty)
        let inside = try await catalog.items(in: "__MACOSX", of: zip, includeHidden: true)
        // (bsdtar on macOS drops "._" AppleDouble files when creating, so none are in the fixture.)
        #expect(inside.map(\.name).sorted() == ["sub", "x"])
        #expect(inside.allSatisfy { $0.isHidden })
    }

    @Test func encryptedZipNeedsPassword() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeEncryptedZip(["secret.txt": "hush"], password: "secret", in: temp)
        let catalog = ArchiveCatalog()
        let first = await withTimeout(10) { () -> Result<Int, ArchiveError> in
            do throws(ArchiveError) { return .success(try await catalog.index(of: zip).entryCount) } catch { return .failure(error) }
        }
        let firstResult = try #require(first, "listing hung")
        switch firstResult {
        case .success(let count): #expect(count == 1)
        case .failure(let error): #expect(error == .passwordRequired)
        }

        await catalog.invalidate(zip)
        await catalog.setPassword("wrong", for: zip)
        #expect(await catalog.password(for: zip) == "wrong")
        let second = await withTimeout(10) { () -> Result<Int, ArchiveError> in
            do throws(ArchiveError) { return .success(try await catalog.index(of: zip).entryCount) } catch { return .failure(error) }
        }
        let secondResult = try #require(second, "listing with a wrong password hung")
        if case .failure(let error) = secondResult {
            #expect(error == .incorrectPassword)
        }
    }

    @Test func notAnArchiveIsUnsupportedOrUnreadable() async throws {
        let temp = try TemporaryDirectory()
        let fake = try temp.file("x.zip", contents: "just some text\nnot an archive\n")
        let catalog = ArchiveCatalog()
        do {
            _ = try await catalog.index(of: fake)
            Issue.record("expected an error")
        } catch {
            switch error {
            case .unsupported, .unreadable: break
            default: Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test func cacheReusedUntilFileChanges() async throws {
        let temp = try TemporaryDirectory()
        let zip = try ArchiveFixtures.makeArchive(["a.txt": "a"], format: "zip", in: temp, name: "c.zip")
        let catalog = ArchiveCatalog()
        #expect(try await catalog.index(of: zip).entryCount == 1)
        #expect(await catalog.runCount == 1)
        #expect(try await catalog.index(of: zip).entryCount == 1)
        _ = try await catalog.items(in: "", of: zip, includeHidden: false)
        #expect(await catalog.runCount == 1)

        try FileManager.default.removeItem(at: zip)
        _ = try ArchiveFixtures.makeArchive(["a.txt": "a", "b.txt": "bb"], format: "zip", in: temp, name: "c.zip")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: zip.path)
        #expect(try await catalog.index(of: zip).entryCount == 2)
        #expect(await catalog.runCount == 2)

        await catalog.invalidate(zip)
        _ = try await catalog.index(of: zip)
        #expect(await catalog.runCount == 3)
    }

    @Test func cancellationTerminatesListing() async throws {
        let temp = try TemporaryDirectory()
        let fakeBsdtar = try temp.file("slow-bsdtar", contents: "#!/bin/sh\nexec /bin/sleep 30\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBsdtar.path)
        let archive = try temp.file("a.zip", contents: "x")
        let catalog = ArchiveCatalog(bsdtar: fakeBsdtar)
        let task = Task { () -> ArchiveError? in
            do throws(ArchiveError) { _ = try await catalog.index(of: archive); return nil } catch { return error }
        }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test(arguments: [
        ("Enter passphrase: Couldn't read passphrase", false, ArchiveError.passwordRequired),
        ("bsdtar: Incorrect passphrase", true, .incorrectPassword),
        ("bsdtar: Error opening archive: Unrecognized archive format", false,
         .unsupported(message: "bsdtar: Error opening archive: Unrecognized archive format")),
        ("bsdtar: RAR solid archive not supported", false,
         .unsupported(message: "bsdtar: RAR solid archive not supported")),
        ("bsdtar: Truncated input file\n", false, .unreadable(message: "bsdtar: Truncated input file")),
    ])
    func errorMapping(stderr: String, hadPassword: Bool, expected: ArchiveError) {
        #expect(ArchiveCatalog.error(stderr: stderr, hadPassword: hadPassword) == expected)
    }

    @Test func formatLists() {
        let url = { (name: String) in URL(fileURLWithPath: "/tmp/\(name)") }
        #expect(ArchiveFormats.isArchive(url("a.TAR.GZ")))
        #expect(ArchiveFormats.isArchive(url("a.zip")))
        #expect(ArchiveFormats.isArchive(url("a.7z")))
        #expect(!ArchiveFormats.isArchive(url("a.docx")))
        #expect(!ArchiveFormats.isArchive(url("a.dmg")))
        #expect(!ArchiveFormats.isArchive(url("gz")))
        #expect(ArchiveFormats.isBrowsable(url("a.docx")))
        #expect(ArchiveFormats.isBrowsable(url("a.tar.bz2")))
        #expect(!ArchiveFormats.isBrowsable(url("a.dmg")))
        #expect(!ArchiveFormats.isBrowsable(url("a.app")))
    }

    /// Shown by receivers of a failed file promise (Finder), so the text must be readable.
    @Test func errorDescriptions() {
        #expect(ArchiveError.passwordRequired.errorDescription == "The archive is encrypted. Enter its password to extract it.")
        #expect(ArchiveError.incorrectPassword.errorDescription == "The password you entered is incorrect.")
        #expect(ArchiveError.cancelled.errorDescription == "The operation was cancelled.")
        #expect(ArchiveError.unreadable(message: "Bad data").errorDescription == "Bad data")
        #expect(ArchiveError.unsupported(message: "Unrecognized archive format").errorDescription == "Unrecognized archive format")
        #expect((ArchiveError.incorrectPassword as any Error).localizedDescription == "The password you entered is incorrect.")
    }
}
