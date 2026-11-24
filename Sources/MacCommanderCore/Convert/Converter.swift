import Darwin
import Foundation
import Synchronization

/// Why a single conversion failed.
public enum ConvertError: Error, Equatable, Sendable {
    /// The tool's first non-empty stderr line (ffmpeg's last one: it prints its input summary first),
    /// or "<tool> failed (status n)".
    case toolFailed(String)
    case disc(DiscImageError)
    /// Kept inspectable: the batch asks for a password on `.passwordRequired` / `.incorrectPassword`.
    case archive(ArchiveError)
}

extension ConvertError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .toolFailed(let message): message
        case .disc(let error): error.errorDescription
        case .archive(let error): error.errorDescription
        }
    }
}

/// What one conversion produced.
public struct ConvertOutcome: Sendable, Equatable {
    public let output: URL
    /// MODE2 Form 2 sectors written as zeros (ISO only; 0 otherwise).
    public let zeroFilledSectors: Int
}

/// Converts one file next to itself (spec §2.3, §2.6). The output is written under its final name inside a
/// hidden `.mc-partial-<UUID>` folder beside the source, then renamed into place without overwriting.
/// The temporary folder is removed afterwards, also on failure or cancellation.
public enum Converter {
    static let bsdtar = URL(filePath: "/usr/bin/bsdtar")
    private static let compoundSuffixes: Set<String> = ["gz", "bz2", "xz"]

    /// Converts one file next to it (spec §2.3, §2.6). `password` is for archives. Never overwrites.
    /// `progress` (0...1) is reported for video, ffmpeg and ISO conversions, possibly from a background thread.
    /// Cancellation terminates the running tool and throws `CancellationError`.
    @concurrent public static func convert(
        _ source: URL, to target: ConvertTarget, ffmpeg: URL?, password: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConvertOutcome {
        try Task.checkCancellation()
        let folder = source.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(ArchiveExtractor.stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(
            at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // removeStaging only deletes `.mc-partial-*` folders and first makes staged folders writable.
        defer { ArchiveExtractor.removeStaging(temp) }

        let stem = outputStem(of: source)
        let output = temp.appendingPathComponent(stem + "." + target.fileExtension)
        var zeroed = 0
        switch target {
        case .pdf:
            // Only the text system's work runs on the main actor; the share is read and written here.
            let document = try Data(contentsOf: source)
            let ext = source.pathExtension
            let pdf = try await MainActor.run { try DocumentPDFRenderer.render(document, fileExtension: ext) }
            try pdf.write(to: output, options: .withoutOverwriting)
        case .iso:
            do {
                zeroed = try await DiscImageWriter.writeISO(cue: source, to: output, progress: progress)
            } catch let error as DiscImageError {
                throw ConvertError.disc(error)
            }
        case .zip, .tarGz, .sevenZip:
            try await pack(source, to: output, target: target, temp: temp, password: password)
        default:
            try await runTools(source, target: target, output: output, ffmpeg: ffmpeg, progress: progress)
        }
        try Task.checkCancellation()
        let placed = try moveIntoPlace(output, stem: stem, fileExtension: target.fileExtension, in: folder)
        return ConvertOutcome(output: placed, zeroFilledSectors: zeroed)
    }

    /// Source name without its extension; a compound archive extension goes whole (`a.tar.gz` → `a`).
    static func outputStem(of source: URL) -> String {
        var url = source
        if compoundSuffixes.contains(url.pathExtension.lowercased()),
            url.deletingPathExtension().pathExtension.lowercased() == "tar"
        {
            url = url.deletingPathExtension()
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Steps

    /// Runs the target's invocations in order; the first with exit status 0 wins. Video and ffmpeg runs
    /// report progress parsed from the tool's output.
    private static func runTools(
        _ source: URL, target: ConvertTarget, output: URL, ffmpeg: URL?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let codecs = target == .mp4FFmpeg ? await probeCodecs(source, ffmpeg: ffmpeg) : nil
        let invocations = ConvertCommand.invocations(
            source: source, target: target, output: output, ffmpeg: ffmpeg, codecs: codecs)
        guard !invocations.isEmpty else {
            throw ConvertError.toolFailed(L10n.string("convert.error.needsFFmpeg", "This conversion needs ffmpeg (brew install ffmpeg)."))
        }
        var failure = ConvertError.toolFailed("")
        for invocation in invocations {
            try Task.checkCancellation()
            // A failed attempt may leave a partial file; the next one starts clean.
            try? FileManager().removeItem(at: output)
            let result = try await ProcessRunner.run(
                invocation.executable, invocation.arguments, onLine: lineHandler(for: target, progress: progress))
            if result.status == 0 { return }
            // ffmpeg prints its input summary first; its actual error is the last line.
            failure = toolFailure(
                result, tool: invocation.executable.lastPathComponent, lastLine: target.needsFFmpeg)
        }
        throw failure
    }

    /// The source's codecs from the `ffprobe` beside `ffmpeg`; nil when there is none or it fails.
    private static func probeCodecs(_ source: URL, ffmpeg: URL?) async -> MediaCodecs? {
        guard let ffprobe = ffmpeg?.deletingLastPathComponent().appendingPathComponent("ffprobe"),
            FileManager().isExecutableFile(atPath: ffprobe.path),
            let result = try? await ProcessRunner.run(ffprobe, ConvertCommand.ffprobeArguments(source: source)),
            result.status == 0
        else { return nil }
        return ConvertCommand.mediaCodecs(ffprobeOutput: String(decoding: result.stdout, as: UTF8.self))
    }

    /// Progress parsing for the tools that print it. `onLine` may run on both drain threads at once,
    /// so the ffmpeg duration seen on stderr is shared through a Mutex.
    private static func lineHandler(
        for target: ConvertTarget, progress: @escaping @Sendable (Double) -> Void
    ) -> (@Sendable (String) -> Void)? {
        switch target {
        case .mp4H264, .movHEVC:
            return { line in
                if let value = ConvertCommand.avconvertProgress(line) { progress(value) }
            }
        case .mp3, .flac, .mp4FFmpeg:
            let duration = Mutex<Int64?>(nil)
            return { line in
                if let value = ConvertCommand.ffmpegDuration(line) {
                    // The first Duration line is the input's; later ones (output summary) are ignored.
                    duration.withLock { if $0 == nil { $0 = value } }
                } else if let value = ConvertCommand.ffmpegProgress(line, durationMicroseconds: duration.withLock { $0 }) {
                    progress(value)
                }
            }
        default:
            return nil
        }
    }

    /// The first (or with `lastLine`, the last) non-empty stderr line, else "<tool> failed (status n)".
    private static func toolFailure(_ result: ProcessOutput, tool: String, lastLine: Bool = false) -> ConvertError {
        let lines = result.stderr.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let line = lastLine ? lines.last : lines.first
        return .toolFailed(line ?? L10n.format("convert.error.toolFailed", "%1$@ failed (status %2$lld)", tool, Int(result.status)))
    }

    /// Extracts the whole archive into staging inside `temp`, then packs the staged top-level items.
    private static func pack(
        _ source: URL, to output: URL, target: ConvertTarget, temp: URL, password: String?
    ) async throws {
        let staged: (staging: URL, items: [URL])
        do {
            staged = try await ArchiveExtractor.stage([""], from: source, near: temp, password: password)
        } catch let error as ArchiveError {
            throw ConvertError.archive(error)
        }
        defer { ArchiveExtractor.removeStaging(staged.staging) }
        let format: [String] =
            switch target {
            case .zip: ["--format", "zip"]
            case .tarGz: ["-z", "--format", "pax"]
            default: ["--format", "7zip"]
            }
        // "./" keeps a name starting with "@" from being read as bsdtar's "@archive" operand;
        // `-s` strips it again from the stored entry names.
        let names = staged.items.map { "./" + $0.lastPathComponent }
        let result = try await ProcessRunner.run(
            bsdtar, ["-c", "-f", output.path] + format + ["-s", ",^\\./,,"] + ["--"] + names,
            currentDirectory: staged.staging)
        if result.status != 0 { throw toolFailure(result, tool: "bsdtar") }
    }

    /// Renames `output` next to the source under the Keep Both name, never over an existing item.
    /// If the name is taken between choosing and renaming, the next free name is tried (up to 100 times).
    private static func moveIntoPlace(_ output: URL, stem: String, fileExtension: String, in folder: URL) throws -> URL {
        let fileManager = FileManager()
        for _ in 0..<100 {
            // keepBothName splits only the last extension ("a.tar 2.gz"); compound ones keep it whole.
            let name =
                fileExtension.contains(".")
                ? NameGenerator.uniqueName(base: stem, pathExtension: fileExtension, in: folder, fileManager: fileManager)
                : NameGenerator.keepBothName(for: output.lastPathComponent, isDirectory: false, in: folder,
                                             fileManager: fileManager)
            let target = folder.appendingPathComponent(name)
            let code = FileTransfer.exclusiveRename(output, to: target)
            if code == 0 { return target }
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.path])
    }
}
