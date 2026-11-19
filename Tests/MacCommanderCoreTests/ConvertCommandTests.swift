import Foundation
import Testing

@testable import MacCommanderCore

struct ConvertCommandTests {
    private let src = URL(filePath: "/in/a.src")
    private let out = URL(filePath: "/tmp/.mc-partial-x/a.out")
    private let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")

    private func single(_ target: ConvertTarget) -> ToolInvocation? {
        let list = ConvertCommand.invocations(source: src, target: target, output: out, ffmpeg: ffmpeg)
        #expect(list.count == 1)
        return list.first
    }

    @Test func jpeg() {
        let call = single(.jpeg)
        #expect(call?.executable.path == "/usr/bin/sips")
        #expect(call?.arguments == ["-s", "format", "jpeg", "-s", "formatOptions", "85", "/in/a.src", "--out", out.path])
    }

    @Test func pngHeicTiff() {
        for (target, format) in [(ConvertTarget.png, "png"), (.heic, "heic"), (.tiff, "tiff")] {
            let call = single(target)
            #expect(call?.executable.path == "/usr/bin/sips")
            #expect(call?.arguments == ["-s", "format", format, "/in/a.src", "--out", out.path])
        }
    }

    @Test func m4a() {
        let call = single(.m4a)
        #expect(call?.executable.path == "/usr/bin/afconvert")
        #expect(call?.arguments == ["-f", "m4af", "-d", "aac", "-b", "256000", "/in/a.src", out.path])
    }

    @Test func wav() {
        let call = single(.wav)
        #expect(call?.executable.path == "/usr/bin/afconvert")
        #expect(call?.arguments == ["-f", "WAVE", "-d", "LEI16", "/in/a.src", out.path])
    }

    @Test func aiff() {
        let call = single(.aiff)
        #expect(call?.executable.path == "/usr/bin/afconvert")
        #expect(call?.arguments == ["-f", "AIFF", "-d", "BEI16", "/in/a.src", out.path])
    }

    @Test func mp3() {
        let call = single(.mp3)
        #expect(call?.executable == ffmpeg)
        #expect(call?.arguments == [
            "-nostdin", "-hide_banner", "-y", "-i", "/in/a.src", "-vn", "-c:a", "libmp3lame", "-b:a", "192k",
            "-progress", "pipe:1", out.path,
        ])
    }

    @Test func flac() {
        let call = single(.flac)
        #expect(call?.executable == ffmpeg)
        #expect(call?.arguments == [
            "-nostdin", "-hide_banner", "-y", "-i", "/in/a.src", "-vn", "-c:a", "flac", "-progress", "pipe:1", out.path,
        ])
    }

    @Test func mp4H264() {
        let call = single(.mp4H264)
        #expect(call?.executable.path == "/usr/bin/avconvert")
        #expect(call?.arguments == [
            "--source", "/in/a.src", "--preset", "PresetHighestQuality", "--output", out.path, "--progress",
        ])
    }

    @Test func movHEVC() {
        let call = single(.movHEVC)
        #expect(call?.executable.path == "/usr/bin/avconvert")
        #expect(call?.arguments == [
            "--source", "/in/a.src", "--preset", "PresetHEVCHighestQuality", "--output", out.path, "--progress",
        ])
    }

    @Test func mp4FFmpegRemuxThenReencode() {
        let list = ConvertCommand.invocations(source: src, target: .mp4FFmpeg, output: out, ffmpeg: ffmpeg)
        #expect(list.map(\.executable) == [ffmpeg, ffmpeg])
        #expect(list.first?.arguments == [
            "-nostdin", "-hide_banner", "-y", "-i", "/in/a.src", "-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-sn",
            "-movflags", "+faststart", "-progress", "pipe:1", out.path,
        ])
        #expect(list.last?.arguments == [
            "-nostdin", "-hide_banner", "-y", "-i", "/in/a.src", "-map", "0:v:0", "-map", "0:a?",
            "-c:v", "h264_videotoolbox", "-b:v", "8M", "-c:a", "aac", "-b:a", "192k", "-sn",
            "-movflags", "+faststart", "-progress", "pipe:1", out.path,
        ])
    }

    @Test func textutil() {
        for (target, format) in [(ConvertTarget.docx, "docx"), (.rtf, "rtf"), (.txt, "txt"), (.html, "html")] {
            let call = single(target)
            #expect(call?.executable.path == "/usr/bin/textutil")
            #expect(call?.arguments == ["-convert", format, "/in/a.src", "-output", out.path])
        }
    }

    @Test func ffmpegTargetsNeedFFmpeg() {
        for target in [ConvertTarget.mp3, .flac, .mp4FFmpeg] {
            #expect(ConvertCommand.invocations(source: src, target: target, output: out, ffmpeg: nil).isEmpty)
        }
    }

    @Test func avconvertProgressParses() {
        #expect(ConvertCommand.avconvertProgress("avconvert progress:  42.50% complete") == 0.425)
        #expect(ConvertCommand.avconvertProgress("avconvert progress: 100.00% complete") == 1)
        #expect(ConvertCommand.avconvertProgress("Some other line") == nil)
    }

    @Test func ffmpegProgressParses() {
        #expect(ConvertCommand.ffmpegProgress("out_time_us=1000000", durationMicroseconds: 2_000_000) == 0.5)
        #expect(ConvertCommand.ffmpegProgress("out_time_us=5000000", durationMicroseconds: 2_000_000) == 1)
        #expect(ConvertCommand.ffmpegProgress("out_time_us=1000000", durationMicroseconds: nil) == nil)
        #expect(ConvertCommand.ffmpegProgress("out_time_us=N/A", durationMicroseconds: 2_000_000) == nil)
        #expect(ConvertCommand.ffmpegProgress("progress=end", durationMicroseconds: 2_000_000) == nil)
    }

    @Test func ffmpegDurationParses() {
        #expect(ConvertCommand.ffmpegDuration("  Duration: 00:01:02.50, start: 0.000000, bitrate: 128 kb/s")
            == 62_500_000)
        #expect(ConvertCommand.ffmpegDuration("  Duration: 01:00:00.00, start: 0") == 3_600_000_000)
        #expect(ConvertCommand.ffmpegDuration("  Duration: N/A, bitrate: N/A") == nil)
        #expect(ConvertCommand.ffmpegDuration("frame=1") == nil)
    }
}
