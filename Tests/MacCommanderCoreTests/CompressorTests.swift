import Foundation
import Testing
@testable import MacCommanderCore

struct CompressorTests {
    @Test(.english) func compressSingleAndMultiple() async throws {
        let tmp = try TemporaryDirectory()
        let a = try tmp.file("a.txt", contents: "A")
        let b = try tmp.file("b.txt", contents: "B")

        let single = try await Compressor.compress([a])
        #expect(single.lastPathComponent == "a.txt.zip")
        #expect(FileManager.default.fileExists(atPath: single.path))

        let archive = try await Compressor.compress([a, b])
        #expect(archive.lastPathComponent == "Archive.zip")
        let second = try await Compressor.compress([a, b])
        #expect(second.lastPathComponent == "Archive 2.zip")

        let listing = try unzipList(archive)
        #expect(listing.contains("a.txt"))
        #expect(listing.contains("b.txt"))
        #expect(!listing.contains { $0.contains("/") && !$0.hasPrefix("__MACOSX/") })

        // Sources untouched, no staging or temporary items left behind.
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).sorted()
        #expect(names == ["Archive 2.zip", "Archive.zip", "a.txt", "a.txt.zip", "b.txt"])
    }

    @Test func itemsFromDifferentFoldersAreRefused() async throws {
        let tmp = try TemporaryDirectory()
        let a = try tmp.file("x/a.txt", contents: "A")
        let b = try tmp.file("y/b.txt", contents: "B")
        await #expect(throws: CocoaError.self) { try await Compressor.compress([a, b]) }
    }

    @Test func cancelLeavesNoArchive() async throws {
        let tmp = try TemporaryDirectory()
        let big = tmp.url.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        // Incompressible data keeps ditto busy long enough to be cancelled.
        var chunk = Data(count: 1 << 20)
        chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        for _ in 0..<128 { try handle.write(contentsOf: chunk) }
        try handle.close()

        let task = Task { try await Compressor.compress([big]) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result

        // 128 MB of random data takes ditto far longer than 50 ms: cancelling terminates it.
        #expect(throws: CancellationError.self) { try result.get() }
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        #expect(names == ["big.bin"])
    }
}

func unzipList(_ zip: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-l", zip.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    // Entries sit between the two dashed rules: "  Length  Date  Time  Name".
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    let rules = lines.indices.filter { lines[$0].hasPrefix("---") }
    guard rules.count >= 2 else { return [] }
    return lines[(rules[0] + 1)..<rules[1]].map { line in
        line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).dropFirst(3)
            .joined().trimmingCharacters(in: .whitespaces)
    }
}
