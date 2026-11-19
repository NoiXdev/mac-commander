import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import MacCommanderCore

struct ConverterTests {
    // MARK: - Fixtures

    private func png(_ name: String, in dir: TemporaryDirectory) throws -> URL {
        let url = dir.url.appendingPathComponent(name)
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

    /// 16-bit mono 44.1 kHz PCM, 0.1 s of silence.
    private func wav(_ name: String, in dir: TemporaryDirectory) throws -> URL {
        let samples = 4410
        let dataBytes = UInt32(samples * 2)
        var data = Data()
        func le32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        le32(36 + dataBytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        le32(16)
        le16(1)  // PCM
        le16(1)  // mono
        le32(44100)
        le32(44100 * 2)
        le16(2)
        le16(16)
        data.append(contentsOf: Array("data".utf8))
        le32(dataBytes)
        #expect(data.count == 44)
        data.append(Data(count: Int(dataBytes)))
        let url = dir.url.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func script(_ body: String, in dir: TemporaryDirectory) throws -> URL {
        let url = dir.url.appendingPathComponent("tools/ffmpeg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func contents(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func convert(_ source: URL, _ target: ConvertTarget, ffmpeg: URL? = nil) async throws -> ConvertOutcome {
        try await Converter.convert(source, to: target, ffmpeg: ffmpeg, password: nil, progress: { _ in })
    }

    // MARK: - Tests

    @Test func pngToJPEG() async throws {
        let dir = try TemporaryDirectory()
        let source = try png("a.png", in: dir)
        let outcome = try await convert(source, .jpeg)
        #expect(outcome.output.lastPathComponent == "a.jpg")
        #expect(outcome.output.deletingLastPathComponent().standardizedFileURL == dir.url.standardizedFileURL)
        #expect(outcome.zeroFilledSectors == 0)
        let image = try #require(CGImageSourceCreateWithURL(outcome.output as CFURL, nil))
        #expect(CGImageSourceGetType(image) as String? == UTType.jpeg.identifier)
        #expect(try contents(dir.url) == ["a.jpg", "a.png"])
    }

    @Test func txtToRTFAndPDF() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("a.txt", contents: "Hello, converter.\nSecond line.\n")
        let rtf = try await convert(source, .rtf)
        #expect(rtf.output.lastPathComponent == "a.rtf")
        #expect(try String(contentsOf: rtf.output, encoding: .utf8).hasPrefix("{\\rtf"))
        let pdf = try await convert(source, .pdf)
        #expect(pdf.output.lastPathComponent == "a.pdf")
        let document = try #require(PDFDocument(url: pdf.output))
        #expect(document.pageCount >= 1)
        #expect(document.string?.contains("Hello, converter.") == true)
    }

    @Test func htmlToPDF() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("page.html", contents: "<html><body><h1>Title here</h1><p>Body text.</p></body></html>")
        let pdf = try await convert(source, .pdf)
        let document = try #require(PDFDocument(url: pdf.output))
        #expect(document.string?.contains("Title here") == true)
        #expect(document.string?.contains("<h1>") == false)
    }

    @Test func wavToM4A() async throws {
        let dir = try TemporaryDirectory()
        let source = try wav("a.wav", in: dir)
        let outcome = try await convert(source, .m4a)
        #expect(outcome.output.lastPathComponent == "a.m4a")
        let size = try FileManager.default.attributesOfItem(atPath: outcome.output.path)[.size] as? Int
        #expect((size ?? 0) > 0)
    }

    @Test func zipToTarGzKeepsEntries() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("stuff/one.txt", contents: "one")
        try dir.file("stuff/sub/two.txt", contents: "two")
        let zip = dir.url.appendingPathComponent("stuff.zip")
        let made = try await ProcessRunner.run(
            URL(filePath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", dir.url.appendingPathComponent("stuff").path, zip.path])
        #expect(made.status == 0)
        let outcome = try await convert(zip, .tarGz)
        #expect(outcome.output.lastPathComponent == "stuff.tar.gz")
        let list = try await ProcessRunner.run(URL(filePath: "/usr/bin/bsdtar"), ["-tf", outcome.output.path])
        let entries = Set(String(decoding: list.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(entries.isSuperset(of: ["stuff/one.txt", "stuff/sub/two.txt"]))
        #expect(!entries.contains { $0.contains(".mc-partial-") })
        #expect(try contents(dir.url) == ["stuff", "stuff.tar.gz", "stuff.zip"])
    }

    @Test func repackKeepsAtSignNames() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("in/@notes.txt", contents: "notes")
        try dir.file("in/plain.txt", contents: "plain")
        let tgz = dir.url.appendingPathComponent("at.tar.gz")
        let made = try await ProcessRunner.run(
            URL(filePath: "/usr/bin/bsdtar"),
            ["-c", "-z", "-f", tgz.path, "-C", dir.url.appendingPathComponent("in").path, "--", "./@notes.txt", "plain.txt"])
        #expect(made.status == 0)
        let outcome = try await convert(tgz, .zip)
        let list = try await ProcessRunner.run(URL(filePath: "/usr/bin/bsdtar"), ["-tf", outcome.output.path])
        let entries = Set(String(decoding: list.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(entries == ["@notes.txt", "plain.txt"])
    }

    @Test func compoundExtensionsStayWhole() async throws {
        let dir = try TemporaryDirectory()
        try dir.file("in/one.txt", contents: "one")
        let tgz = dir.url.appendingPathComponent("b.tar.gz")
        let made = try await ProcessRunner.run(
            URL(filePath: "/usr/bin/bsdtar"), ["-c", "-z", "-f", tgz.path, "-C", dir.url.path, "in"])
        #expect(made.status == 0)
        #expect(try await convert(tgz, .zip).output.lastPathComponent == "b.zip")
        let zip = dir.url.appendingPathComponent("b.zip")
        #expect(try await convert(zip, .tarGz).output.lastPathComponent == "b 2.tar.gz")
    }

    @Test func cueToISOReportsZeroSectors() async throws {
        let dir = try TemporaryDirectory()
        var bin = Data()
        for submode: UInt8 in [0x08, 0x20, 0x08] {
            var sector = Data(repeating: 0x5A, count: 2352)
            sector[18] = submode
            bin.append(sector)
        }
        try bin.write(to: dir.url.appendingPathComponent("game.bin"))
        let cue = try dir.file("game.cue", contents: "FILE \"game.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\n")
        let outcome = try await convert(cue, .iso)
        #expect(outcome.output.lastPathComponent == "game.iso")
        #expect(outcome.zeroFilledSectors == 1)
        #expect(try Data(contentsOf: outcome.output).count == 3 * 2048)
    }

    @Test func neverOverwritesExistingOutput() async throws {
        let dir = try TemporaryDirectory()
        let source = try png("a.png", in: dir)
        let existing = try dir.file("a.jpg", contents: "keep me")
        let before = try Data(contentsOf: existing)
        let outcome = try await convert(source, .jpeg)
        #expect(outcome.output.lastPathComponent == "a 2.jpg")
        #expect(try Data(contentsOf: existing) == before)
        #expect(try contents(dir.url) == ["a 2.jpg", "a.jpg", "a.png"])
    }

    @Test func failureLeavesNothingBehind() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("x.png", contents: "this is not an image")
        await #expect {
            _ = try await convert(source, .jpeg)
        } throws: { error in
            guard case ConvertError.toolFailed(let message) = error else { return false }
            return !message.isEmpty
        }
        #expect(try contents(dir.url) == ["x.png"])
    }

    @Test func cancelLeavesNothingBehind() async throws {
        let dir = try TemporaryDirectory()
        let source = try wav("a.wav", in: dir)
        let ffmpeg = try script("exec sleep 30", in: dir)
        let start = Date()
        let task = Task { try await convert(source, .mp3, ffmpeg: ffmpeg) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(try contents(dir.url) == ["a.wav", "tools"])
    }

    @Test func ffmpegFallsBackToReencode() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("v.mkv", contents: "video")
        let log = dir.url.appendingPathComponent("tools/log.txt")
        let ffmpeg = try script("""
            echo "$*" >> '\(log.path)'
            case "$*" in *"-c copy"*) echo "remux failed" >&2; exit 1;; esac
            eval last=\\${$#}
            echo encoded > "$last"
            """, in: dir)
        let outcome = try await convert(source, .mp4FFmpeg, ffmpeg: ffmpeg)
        #expect(outcome.output.lastPathComponent == "v.mp4")
        #expect(try String(contentsOf: outcome.output, encoding: .utf8) == "encoded\n")
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(calls.count == 2)
        #expect(calls.first?.contains("-c copy") == true)
        #expect(calls.last?.contains("h264_videotoolbox") == true)
        #expect(try contents(dir.url) == ["tools", "v.mkv", "v.mp4"])
    }

    /// A fake `ffprobe` beside the fake ffmpeg (same `tools/` folder).
    private func ffprobe(_ body: String, in dir: TemporaryDirectory) throws {
        let url = dir.url.appendingPathComponent("tools/ffprobe")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func loggingFFmpeg(_ log: URL, in dir: TemporaryDirectory) throws -> URL {
        try script("""
            echo "$*" >> '\(log.path)'
            eval last=\\${$#}
            echo encoded > "$last"
            """, in: dir)
    }

    @Test func ffprobeDecidesRemuxCodecs() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("v.mkv", contents: "video")
        let log = dir.url.appendingPathComponent("tools/log.txt")
        let ffmpeg = try loggingFFmpeg(log, in: dir)
        try ffprobe("""
            case "$*" in *"stream=codec_type,codec_name"*"v.mkv") ;; *) exit 1;; esac
            printf 'codec_name=hevc\\ncodec_type=video\\ncodec_name=flac\\ncodec_type=audio\\n'
            """, in: dir)
        _ = try await convert(source, .mp4FFmpeg, ffmpeg: ffmpeg)
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(calls.count == 1)
        #expect(calls.first?.contains("-c:v copy -tag:v hvc1 -c:a aac -b:a 192k") == true)
        #expect(try contents(dir.url) == ["tools", "v.mkv", "v.mp4"])
    }

    @Test func failingFFprobeKeepsPlainRemux() async throws {
        let dir = try TemporaryDirectory()
        let source = try dir.file("v.mkv", contents: "video")
        let log = dir.url.appendingPathComponent("tools/log.txt")
        let ffmpeg = try loggingFFmpeg(log, in: dir)
        try ffprobe("echo 'Invalid data' >&2; exit 1", in: dir)
        _ = try await convert(source, .mp4FFmpeg, ffmpeg: ffmpeg)
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(calls.first?.contains("-c copy") == true)
    }

    @Test func ffmpegFailureReportsStderr() async throws {
        let dir = try TemporaryDirectory()
        let source = try wav("a.wav", in: dir)
        let ffmpeg = try script(
            "echo 'Input #0, wav, from a.wav:' >&2; echo '  Duration: 00:00:00.10' >&2; echo 'Error: bad codec' >&2; echo '' >&2; exit 1",
            in: dir)
        await #expect(throws: ConvertError.toolFailed("Error: bad codec")) {
            _ = try await convert(source, .mp3, ffmpeg: ffmpeg)
        }
        #expect(try contents(dir.url) == ["a.wav", "tools"])
    }

    @Test func ffmpegProgressIsReported() async throws {
        let dir = try TemporaryDirectory()
        let source = try wav("a.wav", in: dir)
        let ffmpeg = try script("""
            echo "  Duration: 00:00:02.00, start: 0.000000" >&2
            sleep 0.3
            echo "out_time_us=1000000"
            echo "progress=end"
            eval last=\\${$#}
            echo audio > "$last"
            """, in: dir)
        let seen = Mutex<[Double]>([])
        _ = try await Converter.convert(source, to: .mp3, ffmpeg: ffmpeg, password: nil) { value in
            seen.withLock { $0.append(value) }
        }
        #expect(seen.withLock { $0 }.contains(0.5))
    }
}
