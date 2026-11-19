import Foundation

/// One run of a command-line tool.
public struct ToolInvocation: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// Codecs of a media file as ffprobe names them (lowercased): the first video stream's and every audio stream's.
public struct MediaCodecs: Equatable, Sendable {
    public let video: String?
    public let audio: [String]

    public init(video: String?, audio: [String]) {
        self.video = video
        self.audio = audio
    }
}

/// The tool command lines behind each conversion target (spec §2.2), and their progress parsers.
public enum ConvertCommand {
    static let sips = URL(filePath: "/usr/bin/sips")
    static let afconvert = URL(filePath: "/usr/bin/afconvert")
    static let avconvert = URL(filePath: "/usr/bin/avconvert")
    static let textutil = URL(filePath: "/usr/bin/textutil")

    /// Exact invocations for process-based targets (not pdf, iso, archives), tried in order until one
    /// succeeds. Empty for the in-process targets and for ffmpeg targets when `ffmpeg` is nil.
    /// `-y` is safe for ffmpeg: `output` is always inside the converter's private temporary folder.
    /// `codecs` (ffprobe's view of the source) decides what the MP4 remux copies; nil copies everything.
    public static func invocations(
        source: URL, target: ConvertTarget, output: URL, ffmpeg: URL?, codecs: MediaCodecs? = nil
    ) -> [ToolInvocation] {
        let src = source.path
        let out = output.path
        switch target {
        case .jpeg:
            return [ToolInvocation(
                executable: sips, arguments: ["-s", "format", "jpeg", "-s", "formatOptions", "85", src, "--out", out])]
        case .png, .heic, .tiff:
            return [ToolInvocation(executable: sips, arguments: ["-s", "format", target.rawValue, src, "--out", out])]
        case .m4a:
            // 256 kbit/s is refused for low sample rates (22.05 kHz mono); then afconvert picks the bit rate.
            return [
                ToolInvocation(executable: afconvert, arguments: ["-f", "m4af", "-d", "aac", "-b", "256000", src, out]),
                ToolInvocation(executable: afconvert, arguments: ["-f", "m4af", "-d", "aac", src, out]),
            ]
        case .wav:
            return [ToolInvocation(executable: afconvert, arguments: ["-f", "WAVE", "-d", "LEI16", src, out])]
        case .aiff:
            return [ToolInvocation(executable: afconvert, arguments: ["-f", "AIFF", "-d", "BEI16", src, out])]
        case .mp3, .flac, .mp4FFmpeg:
            guard let ffmpeg else { return [] }
            let head = ["-nostdin", "-hide_banner", "-y", "-i", src]
            let tail = ["-progress", "pipe:1", out]
            let middles: [[String]]
            switch target {
            case .mp3: middles = [["-vn", "-c:a", "libmp3lame", "-b:a", "192k"]]
            case .flac: middles = [["-vn", "-c:a", "flac"]]
            default:
                // Remux first; if that fails, re-encode to H.264/AAC at the source resolution.
                let maps = ["-map", "0:v:0", "-map", "0:a?"]
                let finish = ["-sn", "-movflags", "+faststart"]
                let reencode = maps + reencodeVideo + reencodeAudio + finish
                let remux = maps + (codecs.map(mp4Codecs) ?? ["-c", "copy"]) + finish
                middles = remux == reencode ? [reencode] : [remux, reencode]
            }
            return middles.map { ToolInvocation(executable: ffmpeg, arguments: head + $0 + tail) }
        case .mp4H264, .movHEVC:
            let preset = target == .mp4H264 ? "PresetHighestQuality" : "PresetHEVCHighestQuality"
            return [ToolInvocation(
                executable: avconvert,
                arguments: ["--source", src, "--preset", preset, "--output", out, "--progress"])]
        case .docx, .rtf, .txt, .html:
            // An HTML source would otherwise fetch its remote images and style sheets.
            let noLoad = ["html", "htm"].contains(source.pathExtension.lowercased()) ? ["-noload"] : []
            return [ToolInvocation(
                executable: textutil, arguments: ["-convert", target.rawValue] + noLoad + [src, "-output", out])]
        case .pdf, .zip, .tarGz, .sevenZip, .iso:
            return []
        }
    }

    private static let reencodeVideo = ["-c:v", "h264_videotoolbox", "-b:v", "8M"]
    private static let reencodeAudio = ["-c:a", "aac", "-b:a", "192k"]
    /// Audio codecs an MP4 plays as they are.
    private static let mp4Audio: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]

    /// The codec options of an MP4 remux that QuickTime can play: H.264 is copied, HEVC copied with the
    /// `hvc1` tag (ffmpeg's default `hev1` doesn't play), anything else re-encoded to H.264. Audio is copied
    /// when every stream is MP4-compatible, else re-encoded to AAC.
    static func mp4Codecs(_ codecs: MediaCodecs) -> [String] {
        let video: [String] =
            switch codecs.video {
            case "h264": ["-c:v", "copy"]
            case "hevc": ["-c:v", "copy", "-tag:v", "hvc1"]
            default: reencodeVideo
            }
        let audio = codecs.audio.allSatisfy(mp4Audio.contains) ? ["-c:a", "copy"] : reencodeAudio
        return video + audio
    }

    /// ffprobe's arguments for `mediaCodecs(ffprobeOutput:)`.
    public static func ffprobeArguments(source: URL) -> [String] {
        ["-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "default=noprint_wrappers=1",
         source.path]
    }

    /// Parses ffprobe's "key=value" lines; a stream ends when one of its keys repeats.
    public static func mediaCodecs(ffprobeOutput: String) -> MediaCodecs {
        var streams: [[String: String]] = []
        var current: [String: String] = [:]
        for line in ffprobeOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard parts.count == 2 else { continue }
            if current[parts[0]] != nil {
                streams.append(current)
                current = [:]
            }
            current[parts[0]] = parts[1]
        }
        if !current.isEmpty { streams.append(current) }
        let video = streams.first { $0["codec_type"] == "video" }?["codec_name"]
        let audio = streams.filter { $0["codec_type"] == "audio" }.compactMap { $0["codec_name"] }
        return MediaCodecs(video: video, audio: audio)
    }

    /// "avconvert progress:  42.50% complete" → 0.425.
    public static func avconvertProgress(_ line: String) -> Double? {
        guard let range = line.range(of: "avconvert progress:") else { return nil }
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let percent = rest.split(separator: "%").first, let value = Double(percent) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    /// ffmpeg `-progress` line "out_time_us=…" as a fraction of `durationMicroseconds` (nil when unknown).
    public static func ffmpegProgress(_ line: String, durationMicroseconds: Int64?) -> Double? {
        guard let duration = durationMicroseconds, duration > 0, line.hasPrefix("out_time_us="),
            let time = Int64(line.dropFirst("out_time_us=".count).trimmingCharacters(in: .whitespaces))
        else { return nil }
        return min(max(Double(time) / Double(duration), 0), 1)
    }

    /// "  Duration: 00:01:02.50, start…" (ffmpeg's input summary on stderr) → 62_500_000 µs.
    public static func ffmpegDuration(_ line: String) -> Int64? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Duration:") else { return nil }
        let value = trimmed.dropFirst("Duration:".count).split(separator: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let parts = value.split(separator: ":")
        guard parts.count == 3, let hours = Int64(parts[0]), let minutes = Int64(parts[1]),
            let seconds = Decimal(string: String(parts[2]), locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        let micros = NSDecimalNumber(decimal: seconds * 1_000_000).int64Value
        return (hours * 3600 + minutes * 60) * 1_000_000 + micros
    }
}
