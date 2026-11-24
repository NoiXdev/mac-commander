import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import MacCommanderCore

/// A folder with a fake `Trash/` and its own archive catalog; the center never touches the real Trash
/// or the shared session passwords.
@MainActor
private struct Fixture {
    let tmp: TemporaryDirectory
    let trashFolder: URL
    let center: FileOperationCenter

    init() throws {
        tmp = try TemporaryDirectory()
        trashFolder = try tmp.folder("Trash")
        let trash = fakeTrash(into: trashFolder)
        center = FileOperationCenter(undo: FileUndoStack(trash: trash), trash: trash, catalog: ArchiveCatalog())
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func png(_ name: String) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// A fake ffmpeg: sleeps when the input name contains "slow" (counted in `slowStarts`), else writes its last
    /// argument.
    func ffmpeg() throws -> URL {
        let url = tmp.url.appendingPathComponent("tools/ffmpeg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = """
            #!/bin/sh
            case "$*" in *slow*) echo started >> "$(dirname "$0")/slow-starts"; exec sleep 30;; esac
            eval last=\\${$#}
            echo encoded > "$last"
            """
        try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// How many slow conversions the fake ffmpeg has started.
    var slowStarts: Int {
        let starts = tmp.url.appendingPathComponent("tools/slow-starts")
        return ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    /// Polls until the fake ffmpeg has started `count` slow conversions, for up to 20 seconds.
    func waitForSlowStarts(_ count: Int) async throws {
        let start = Date()
        while slowStarts < count, Date().timeIntervalSince(start) < 20 {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func convert(
        _ items: [URL], to target: ConvertTarget, ffmpeg: URL? = nil,
        askPassword: @escaping @Sendable (URL, Bool) async -> String? = { _, _ in nil }
    ) async -> ConvertBatchResult {
        await center.convert(items, to: target, ffmpeg: ffmpeg, askPassword: askPassword)
    }
}

@MainActor
@Suite(.english) struct ConvertOperationTests {
    @Test func convertsBatchAndRegistersUndo() async throws {
        let f = try Fixture()
        let a = try f.png("a.png")
        let b = try f.png("b.png")

        let result = await f.convert([a, b], to: .jpeg)

        #expect(result.outputs.map(\.lastPathComponent) == ["a.jpg", "b.jpg"])
        #expect(result.failures.isEmpty)
        #expect(!result.cancelled)
        #expect(f.center.undo.undoTitle == "Convert")
        #expect(f.center.undo.records.last?.action == .created(result.outputs))

        _ = try await f.center.performUndo()
        #expect(result.outputs.allSatisfy { !f.exists($0) })
        #expect(f.exists(f.trashFolder.appendingPathComponent("a.jpg")))
        #expect(f.exists(f.trashFolder.appendingPathComponent("b.jpg")))
        #expect(f.exists(a) && f.exists(b))
    }

    @Test func partialFailureKeepsOthersAndUndoesOnlyOutputs() async throws {
        let f = try Fixture()
        let good = try f.png("good.png")
        let bad = try f.tmp.file("bad.png", contents: "this is not an image")

        let result = await f.convert([good, bad], to: .jpeg)

        #expect(result.outputs.map(\.lastPathComponent) == ["good.jpg"])
        #expect(result.failures.map(\.source) == [bad])
        #expect(result.failures.first?.message.isEmpty == false)
        #expect(f.center.undo.records.last?.action == .created(result.outputs))
    }

    @Test func nothingProducedNoUndo() async throws {
        let f = try Fixture()
        let bad = try f.tmp.file("bad.png", contents: "this is not an image")

        let result = await f.convert([bad], to: .jpeg)

        #expect(result.outputs.isEmpty)
        #expect(result.failures.count == 1)
        #expect(f.center.undo.undoTitle == nil)
    }

    @Test func binAndCueConvertOnce() async throws {
        let f = try Fixture()
        let bin = f.tmp.url.appendingPathComponent("g.bin")
        try Data(repeating: 7, count: 2048 * 4).write(to: bin)
        let cue = try f.tmp.file("g.cue", contents: "FILE \"g.bin\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\n")

        let result = await f.convert([bin, cue], to: .iso)

        #expect(result.outputs.map(\.lastPathComponent) == ["g.iso"])
        #expect(result.failures.isEmpty)
        #expect(result.zeroFilledSectors == 0)
    }

    @Test func listedWhileRunningAndRemovedAfter() async throws {
        let f = try Fixture()
        let zip = try ArchiveFixtures.makeEncryptedZip(["a.txt": "A"], password: "pw", in: f.tmp)
        let center = f.center
        let seen = Mutex<[(title: String, incorrect: Bool, countsFiles: [Bool])]>([])

        let result = await f.convert([zip], to: .tarGz) { archive, incorrect in
            let titles = await MainActor.run { center.operations.map(\.title) }
            let countsFiles = await MainActor.run { center.operations.map(\.countsFiles) }
            seen.withLock { $0.append((titles.joined(separator: "|"), incorrect, countsFiles)) }
            #expect(archive == zip)
            return incorrect ? "pw" : "wrong"
        }

        let calls = seen.withLock { $0 }
        #expect(calls.map(\.title) == ["Converting “\(zip.lastPathComponent)”…", "Converting “\(zip.lastPathComponent)”…"])
        #expect(calls.map(\.incorrect) == [false, true])
        // The strip shows "1 of 2 files", not bytes.
        #expect(calls.map(\.countsFiles) == [[true], [true]])
        #expect(result.outputs.count == 1)
        #expect(result.failures.isEmpty)
        #expect(await f.center.catalog.password(for: zip) == "pw")
        #expect(f.center.operations.isEmpty)
    }

    @Test func cancelledPasswordPromptSkipsArchive() async throws {
        let f = try Fixture()
        let skipped = try ArchiveFixtures.makeEncryptedZip(["a.txt": "A"], password: "pw", in: f.tmp)
        let opened = try ArchiveFixtures.makeEncryptedZip(["b.txt": "B"], password: "pw", in: f.tmp)

        let result = await f.convert([skipped, opened], to: .tarGz) { archive, _ in
            archive == skipped ? nil : "pw"
        }

        #expect(result.failures == [ConvertFailure(source: skipped, message: "Cancelled")])
        #expect(result.outputs.count == 1)
        #expect(!result.cancelled)
    }

    @Test func sameFormatIsSkippedSilently() async throws {
        let f = try Fixture()
        let jpeg = try f.tmp.file("photo.jpeg", contents: "not read")
        let png = try f.png("a.png")

        let result = await f.convert([jpeg, png], to: .jpeg)

        #expect(result.outputs.map(\.lastPathComponent) == ["a.jpg"])
        #expect(result.failures.isEmpty)
    }

    @Test func cancelStopsBatchAndKeepsFinishedOutputs() async throws {
        let f = try Fixture()
        let first = try f.tmp.file("first.mkv", contents: "video")
        let slow = try f.tmp.file("slow.mkv", contents: "video")
        let last = try f.tmp.file("last.mkv", contents: "video")
        let ffmpeg = try f.ffmpeg()
        let center = f.center

        let task = Task { await center.convert([first, slow, last], to: .mp4FFmpeg, ffmpeg: ffmpeg) { _, _ in nil } }
        // The batch runs one file after another: once the slow one has started, the first one is recorded.
        try await f.waitForSlowStarts(1)
        let id = try #require(center.operations.first?.id)
        let start = Date()
        center.cancel(id)
        let result = await task.value

        #expect(result.cancelled)
        #expect(result.outputs.map(\.lastPathComponent) == ["first.mp4"])
        #expect(result.failures.isEmpty)
        #expect(!f.exists(f.tmp.url.appendingPathComponent("last.mp4")))
        #expect(f.center.undo.records.last?.action == .created(result.outputs))
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func cancelAllEndsEveryOperationAndCleansUp() async throws {
        let f = try Fixture()
        let one = try f.tmp.file("slow1.mkv", contents: "video")
        let two = try f.tmp.file("slow2.mkv", contents: "video")
        let ffmpeg = try f.ffmpeg()
        let center = f.center

        let first = Task { await center.convert([one], to: .mp4FFmpeg, ffmpeg: ffmpeg) { _, _ in nil } }
        let second = Task { await center.convert([two], to: .mp4FFmpeg, ffmpeg: ffmpeg) { _, _ in nil } }
        try await f.waitForSlowStarts(2)
        #expect(center.operations.count == 2)
        let start = Date()
        await center.cancelAll()
        // Returns only after each operation's work has ended: the converters' temporary folders are gone.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.tmp.url.path)
            .filter { $0.hasPrefix(".mc-partial-") }
        #expect(leftovers.isEmpty)
        #expect(Date().timeIntervalSince(start) < 10)

        #expect(await first.value.cancelled)
        #expect(await second.value.cancelled)
        #expect(center.operations.isEmpty)
    }

    @Test func cancelAllWithNothingRunningReturns() async throws {
        let center = try Fixture().center
        await center.cancelAll()
        #expect(center.operations.isEmpty)
    }
}
