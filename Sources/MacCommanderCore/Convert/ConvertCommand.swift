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

/// The tool command lines behind each conversion target (spec §2.2), and their progress parsers.
public enum ConvertCommand {
    static let sips = URL(filePath: "/usr/bin/sips")
    static let afconvert = URL(filePath: "/usr/bin/afconvert")
    static let avconvert = URL(filePath: "/usr/bin/avconvert")
    static let textutil = URL(filePath: "/usr/bin/textutil")

    /// Exact invocations for process-based targets (not pdf, iso, archives), tried in order until one
    /// succeeds. Empty for the in-process targets and for ffmpeg targets when `ffmpeg` is nil.
    /// `-y` is safe for ffmpeg: `output` is always inside the converter's private temporary folder.
    public static func invocations(source: URL, target: ConvertTarget, output: URL, ffmpeg: URL?) -> [ToolInvocation] {
        let src = source.path
        let out = output.path
        switch target {
        case .jpeg:
            return [ToolInvocation(
                executable: sips, arguments: ["-s", "format", "jpeg", "-s", "formatOptions", "85", src, "--out", out])]
        case .png, .heic, .tiff:
            return [ToolInvocation(executable: sips, arguments: ["-s", "format", target.rawValue, src, "--out", out])]
        case .m4a:
            return [ToolInvocation(
                executable: afconvert, arguments: ["-f", "m4af", "-d", "aac", "-b", "256000", src, out])]
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
                middles = [
                    maps + ["-c", "copy"] + finish,
                    maps + ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-c:a", "aac", "-b:a", "192k"] + finish,
                ]
            }
            return middles.map { ToolInvocation(executable: ffmpeg, arguments: head + $0 + tail) }
        case .mp4H264, .movHEVC:
            let preset = target == .mp4H264 ? "PresetHighestQuality" : "PresetHEVCHighestQuality"
            return [ToolInvocation(
                executable: avconvert,
                arguments: ["--source", src, "--preset", preset, "--output", out, "--progress"])]
        case .docx, .rtf, .txt, .html:
            return [ToolInvocation(executable: textutil, arguments: ["-convert", target.rawValue, src, "-output", out])]
        case .pdf, .zip, .tarGz, .sevenZip, .iso:
            return []
        }
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
