import Foundation
import Testing
@testable import MacCommanderCore

struct ArchiveIndexTests {
    /// 2026-11-17 18:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_938_400)

    private func names(_ index: ArchiveIndex, _ folder: String) -> [String]? {
        index.entries(in: folder)?.map { ($0.path as NSString).lastPathComponent }.sorted()
    }

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func parsesFilesFoldersAndSymlinks() throws {
        let listing = """
            drwxr-xr-x  0 daniel staff       0 Nov 17 17:41 ./
            -rw-r--r--  0 daniel staff       3 Nov 17 17:42 ./a b.txt
            drwxr-xr-x  0 daniel staff       0 Nov 17 17:41 ./sub/
            lrwxr-xr-x  0 daniel staff       0 Nov 17 17:41 ./sub/link -> ../a b.txt
            -rw-r--r--  0 daniel staff       2 Jan  2  2020 ./sub/\\303\\204rger\\nneu.md

            """
        let index = ArchiveIndex(listing: listing, now: now)
        #expect(names(index, "") == ["a b.txt", "sub"])
        #expect(names(index, "sub") == ["link", "Ärger\nneu.md"])
        let root = try #require(index.entries(in: ""))
        let file = try #require(root.first { $0.path == "a b.txt" })
        #expect(file.size == 3)
        #expect(!file.isDirectory)
        #expect(file.modified == utc(2026, 11, 17, 17, 42))
        let sub = try #require(root.first { $0.path == "sub" })
        #expect(sub.isDirectory)
        #expect(sub.size == nil)
        let entries = try #require(index.entries(in: "sub"))
        let link = try #require(entries.first { $0.path == "sub/link" })
        #expect(link.isSymlink)
        #expect(!link.isDirectory)
        let old = try #require(entries.first { $0.path == "sub/Ärger\nneu.md" })
        #expect(old.modified == utc(2020, 1, 2))
        #expect(index.entries(in: "nope") == nil)
        #expect(index.entryCount == 4)
    }

    @Test func zipStyleLinesAndOwnersWithSpaces() throws {
        let listing = """
            drwxr-xr-x  0 501    0           0 Nov 17 17:42 d/
            -rw-r--r--  0 501    0           7 Jan  2  2020 d/old.txt
            -rw-r--r--  0 John Q Public Domain Users 12 Dec 31 23:59 d/tab\\there
            """
        let index = ArchiveIndex(listing: listing, now: now)
        #expect(names(index, "d") == ["old.txt", "tab\there"])
        let entries = try #require(index.entries(in: "d"))
        #expect(entries.first { $0.path == "d/old.txt" }?.size == 7)
        let tab = try #require(entries.first { $0.path == "d/tab\there" })
        #expect(tab.size == 12)
        // A time (not a year) "in the future" belongs to the previous year.
        #expect(tab.modified == utc(2025, 12, 31, 23, 59))
    }

    @Test func plainFileNameWithArrowIsNotSplit() {
        let index = ArchiveIndex(listing: """
            -rw-r--r--  0 501    0           1 Nov 17 17:41 d/back\\\\slash -> x.txt
            -rw-r--r--  0 501    0           1 Nov 17 17:41 a b -> c.txt
            """, now: now)
        #expect(names(index, "") == ["a b -> c.txt", "d"])
        #expect(names(index, "d") == ["back\\slash -> x.txt"])
    }

    @Test func symlinkSplitsAtFirstArrow() throws {
        let index = ArchiveIndex(listing: """
            lrwxr-xr-x  0 501    0           0 Nov 17 17:41 ./l -> a -> b
            lrwxr-xr-x  0 501    0           0 Nov 17 17:41 ./garbage -> \\377\\376
            """, now: now)
        #expect(names(index, "") == ["garbage", "l"])
        let entries = try #require(index.entries(in: ""))
        #expect(entries.allSatisfy { $0.isSymlink && !$0.isDirectory })
    }

    @Test func hardlinkIsFileNamedBeforeLinkTo() throws {
        let index = ArchiveIndex(listing: """
            -rw-r--r--  0 danielelskamp wheel       6 Nov 17 17:45 ./a
            hrw-r--r--  0 danielelskamp wheel       0 Nov 17 17:45 ./b link to ./a
            hrw-r--r--  0 danielelskamp wheel       0 Nov 17 17:45 ./c link to ./missing link to x
            """, now: now)
        #expect(names(index, "") == ["a", "b", "c"])
        let entries = try #require(index.entries(in: ""))
        let b = try #require(entries.first { $0.path == "b" })
        #expect(!b.isDirectory && !b.isSymlink)
        #expect(b.size == 6)
        #expect(entries.first { $0.path == "c" }?.size == nil)
    }

    @Test func synthesizesMissingFolders() throws {
        let index = ArchiveIndex(
            listing: "-rw-r--r--  0 501    0           1 Nov 17 17:41 x/y/z.txt\n", now: now)
        let root = try #require(index.entries(in: ""))
        #expect(root.map(\.path) == ["x"])
        #expect(root.first?.isDirectory == true)
        #expect(index.entries(in: "x")?.map(\.path) == ["x/y"])
        #expect(index.entries(in: "x/y")?.map(\.path) == ["x/y/z.txt"])
    }

    @Test func skipsUnsafeAndRootEntries() {
        let listing = """
            drwxr-xr-x  0 501    0           0 Nov 17 17:41 ./
            drwxr-xr-x  0 501    0           0 Nov 17 17:41 /
            -rw-r--r--  0 501    0           1 Nov 17 17:41 ./../evil
            -rw-r--r--  0 501    0           1 Nov 17 17:41 ./a/../../b
            -rw-r--r--  0 501    0           1 Nov 17 17:41 /etc/passwd
            bsdtar: some warning that is not a listing line
            -rw-r--r--  0 501    0           1 Nov 17 17:41 ./ok
            """
        let index = ArchiveIndex(listing: listing, now: now)
        #expect(names(index, "") == ["ok"])
        #expect(index.entryCount == 1)
    }

    @Test func nfdAndNfcAreOneEntry() {
        let index = ArchiveIndex(listing: """
            -rw-r--r--  0 501    0           1 Nov 17 17:41 ./A\\314\\210rger
            -rw-r--r--  0 501    0           2 Nov 17 17:41 ./\\303\\204rger
            """, now: now)
        #expect(index.entryCount == 1)
        #expect(index.entries(in: "")?.first?.size == 2)
    }

    @Test func parsesTwentyThousandEntriesQuickly() {
        var lines: [String] = []
        for folder in 0..<200 {
            lines.append("drwxr-xr-x  0 daniel staff       0 Nov 17 17:41 ./folder\(folder)/")
            for file in 0..<100 {
                lines.append("-rw-r--r--  0 daniel staff \(file) Jan  2  2020 ./folder\(folder)/file \(file).txt")
            }
        }
        let listing = lines.joined(separator: "\n")
        let start = ContinuousClock.now
        let index = ArchiveIndex(listing: listing, now: now)
        let elapsed = ContinuousClock.now - start
        #expect(index.entryCount == 20_200)
        #expect(index.entries(in: "folder7")?.count == 100)
        #expect(elapsed < .seconds(1))
    }

    @Test func containsFolder() {
        let listing = """
            drwxr-xr-x  0 daniel staff       0 Nov 17 17:41 ./sub/
            -rw-r--r--  0 daniel staff       3 Nov 17 17:42 ./sub/deep/a.txt
            -rw-r--r--  0 daniel staff       3 Nov 17 17:42 ./b.txt

            """
        let index = ArchiveIndex(listing: listing, now: now)
        #expect(index.containsFolder(""))
        #expect(index.containsFolder("sub"))
        #expect(index.containsFolder("sub/deep"))
        #expect(index.containsFolder("/sub/deep/"))
        #expect(!index.containsFolder("b.txt"))
        #expect(!index.containsFolder("sub/deep/a.txt"))
        #expect(!index.containsFolder("missing"))
    }
}
