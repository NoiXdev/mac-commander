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

    @Test func m4aFallsBackToDefaultBitrate() {
        let list = ConvertCommand.invocations(source: src, target: .m4a, output: out, ffmpeg: ffmpeg)
        #expect(list.map(\.executable.path) == ["/usr/bin/afconvert", "/usr/bin/afconvert"])
        #expect(list.map(\.arguments) == [
            ["-f", "m4af", "-d", "aac", "-b", "256000", "/in/a.src", out.path],
            ["-f", "m4af", "-d", "aac", "/in/a.src", out.path],
        ])
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

    private func mp4(_ codecs: MediaCodecs) -> [ToolInvocation] {
        ConvertCommand.invocations(source: src, target: .mp4FFmpeg, output: out, ffmpeg: ffmpeg, codecs: codecs)
    }

    private let head = ["-nostdin", "-hide_banner", "-y", "-i", "/in/a.src", "-map", "0:v:0", "-map", "0:a?"]
    private var tail: [String] { ["-sn", "-movflags", "+faststart", "-progress", "pipe:1", out.path] }
    private let reencode = ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-c:a", "aac", "-b:a", "192k"]

    @Test func mp4ProbedH264AndAACCopiesBoth() {
        let list = mp4(MediaCodecs(video: "h264", audio: ["aac", "mp3"]))
        #expect(list.map(\.arguments) == [
            head + ["-c:v", "copy", "-c:a", "copy"] + tail,
            head + reencode + tail,
        ])
    }

    @Test func mp4ProbedHEVCGetsHvc1Tag() {
        let list = mp4(MediaCodecs(video: "hevc", audio: ["ac3", "eac3", "alac"]))
        #expect(list.first?.arguments == head + ["-c:v", "copy", "-tag:v", "hvc1", "-c:a", "copy"] + tail)
        #expect(list.count == 2)
    }

    @Test func mp4ProbedOtherAudioIsReencoded() {
        let list = mp4(MediaCodecs(video: "h264", audio: ["aac", "flac"]))
        #expect(list.first?.arguments == head + ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"] + tail)
        #expect(list.last?.arguments == head + reencode + tail)
    }

    @Test func mp4ProbedNoAudioCopies() {
        let list = mp4(MediaCodecs(video: "hevc", audio: []))
        #expect(list.first?.arguments == head + ["-c:v", "copy", "-tag:v", "hvc1", "-c:a", "copy"] + tail)
    }

    @Test func mp4ProbedVP9OpusReencodesOnce() {
        // The chosen command equals the fallback: it runs once.
        #expect(mp4(MediaCodecs(video: "vp9", audio: ["opus"])).map(\.arguments) == [head + reencode + tail])
        #expect(mp4(MediaCodecs(video: nil, audio: ["vorbis"])).map(\.arguments) == [head + reencode + tail])
    }

    @Test func mp4ProbedOtherVideoKeepsCopiedAudio() {
        let list = mp4(MediaCodecs(video: "mpeg4", audio: ["mp3"]))
        #expect(list.first?.arguments
            == head + ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-c:a", "copy"] + tail)
        #expect(list.count == 2)
    }

    @Test func ffprobeArguments() {
        #expect(ConvertCommand.ffprobeArguments(source: src) == [
            "-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "default=noprint_wrappers=1",
            "/in/a.src",
        ])
    }

    @Test func mediaCodecsParsesFFprobe() {
        let output = """
            codec_name=mjpeg
            codec_type=video
            codec_name=hevc
            codec_type=video
            codec_name=aac
            codec_type=audio
            codec_name=subrip
            codec_type=subtitle
            codec_name=EAC3
            codec_type=audio

            """
        #expect(ConvertCommand.mediaCodecs(ffprobeOutput: output)
            == MediaCodecs(video: "mjpeg", audio: ["aac", "eac3"]))
        #expect(ConvertCommand.mediaCodecs(ffprobeOutput: "codec_type=audio\ncodec_name=opus\n")
            == MediaCodecs(video: nil, audio: ["opus"]))
        #expect(ConvertCommand.mediaCodecs(ffprobeOutput: "") == MediaCodecs(video: nil, audio: []))
    }

    @Test func textutil() {
        for (target, format) in [(ConvertTarget.docx, "docx"), (.rtf, "rtf"), (.txt, "txt"), (.html, "html")] {
            let call = single(target)
            #expect(call?.executable.path == "/usr/bin/textutil")
            #expect(call?.arguments == ["-convert", format, "/in/a.src", "-output", out.path])
        }
    }

    @Test func textutilNoLoadForHTML() {
        for name in ["/in/page.html", "/in/page.HTM"] {
            let list = ConvertCommand.invocations(
                source: URL(filePath: name), target: .docx, output: out, ffmpeg: nil)
            #expect(list.first?.arguments == ["-convert", "docx", "-noload", name, "-output", out.path])
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
