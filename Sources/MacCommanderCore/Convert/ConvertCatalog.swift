import Foundation

public enum ConvertKind: Sendable, Equatable {
    case image, audio, videoNative, videoFFmpeg, document, archive, discImage
}

public enum FFmpegStatus: Sendable, Equatable {
    case missing, broken, available(URL)
}

public struct ConvertMenu: Equatable, Sendable {
    /// In `ConvertTarget.allCases` order.
    public let targets: [ConvertTarget]
    public let ffmpegHint: String?

    public init(targets: [ConvertTarget], ffmpegHint: String?) {
        self.targets = targets
        self.ffmpegHint = ffmpegHint
    }
}

/// Decides which conversion targets the Convert ▸ menu offers for a selection.
public enum ConvertCatalog {
    private static let kindsByExtension: [String: ConvertKind] = {
        var table: [String: ConvertKind] = [:]
        let groups: [(ConvertKind, [String])] = [
            (.image, ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "gif", "bmp", "webp", "avif"]),
            (.audio, ["wav", "aif", "aiff", "m4a", "mp3", "caf", "flac", "aac"]),
            (.videoNative, ["mov", "mp4", "m4v"]),
            (.videoFFmpeg, ["mkv", "avi", "webm", "wmv", "flv"]),
            (.document, ["docx", "doc", "rtf", "odt", "html", "htm", "txt"]),
            (.archive, ["zip", "tar", "tgz", "tar.gz", "tbz", "tar.bz2", "txz", "tar.xz", "7z", "rar"]),
            (.discImage, ["cue"]),
        ]
        for (kind, extensions) in groups {
            for ext in extensions { table[ext] = kind }
        }
        return table
    }()

    private static let targetsByKind: [ConvertKind: [ConvertTarget]] = [
        .image: [.jpeg, .png, .heic, .tiff],
        .audio: [.m4a, .wav, .aiff, .mp3, .flac],
        .videoNative: [.mp4H264, .movHEVC],
        .videoFFmpeg: [.mp4FFmpeg],
        .document: [.docx, .rtf, .txt, .html, .pdf],
        .archive: [.zip, .tarGz, .sevenZip],
        .discImage: [.iso],
    ]

    private static let aliases = [
        "jpeg": "jpg", "tif": "tiff", "htm": "html", "tgz": "tar.gz", "aif": "aiff",
    ]
    private static let compoundExtensions: Set<String> = ["tar.gz", "tar.bz2", "tar.xz"]

    /// Extension (lowercased, compound "tar.gz"/"tar.bz2"/"tar.xz" recognised); empty when none.
    private static func rawExtension(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let inner = url.deletingPathExtension()
        let compound = inner.pathExtension.lowercased() + "." + ext
        if !ext.isEmpty, compoundExtensions.contains(compound) { return compound }
        return ext
    }

    public static func kind(of url: URL, cueExists: (URL) -> Bool) -> ConvertKind? {
        if url.hasDirectoryPath { return nil }
        let ext = rawExtension(of: url)
        if ext == "bin" { return cueExists(cueURL(for: url)) ? .discImage : nil }
        return kindsByExtension[ext]
    }

    public static func formatKey(of url: URL) -> String {
        let ext = rawExtension(of: url)
        return aliases[ext] ?? ext
    }

    public static func menu(for urls: [URL], ffmpeg: FFmpegStatus, cueExists: (URL) -> Bool) -> ConvertMenu {
        guard !urls.isEmpty else { return ConvertMenu(targets: [], ffmpegHint: nil) }
        // Intersect the kind tables; a file's own format is skipped per file at run time, so a
        // target is only hidden when it is every selected file's own format (spec §2.6).
        var common = Set(ConvertTarget.allCases)
        var owns: [String] = []
        for url in urls {
            guard let kind = kind(of: url, cueExists: cueExists) else {
                return ConvertMenu(targets: [], ffmpegHint: nil)
            }
            owns.append(formatKey(of: url))
            common.formIntersection(targetsByKind[kind] ?? [])
        }
        let full = ConvertTarget.allCases.filter { target in
            common.contains(target) && !owns.allSatisfy { $0 == (aliases[target.fileExtension] ?? target.fileExtension) }
        }
        if case .available = ffmpeg { return ConvertMenu(targets: full, ffmpegHint: nil) }
        let shown = full.filter { !$0.needsFFmpeg }
        guard shown.count != full.count else { return ConvertMenu(targets: shown, ffmpegHint: nil) }
        let hint: String
        switch ffmpeg {
        case .broken:
            hint = L10n.string("convert.ffmpeg.broken", "ffmpeg is installed but doesn't start (brew reinstall ffmpeg)")
        default:
            hint = L10n.string("convert.ffmpeg.missing", "More formats need ffmpeg (brew install ffmpeg)")
        }
        return ConvertMenu(targets: shown, ffmpegHint: hint)
    }

    public static func sources(for urls: [URL], cueExists: (URL) -> Bool) -> [URL] {
        // Case-insensitively, as the volume usually is: "G.BIN" with "g.cue" selected is one image.
        let given = Set(urls.map { $0.standardizedFileURL.path.lowercased() })
        var result: [URL] = []
        for url in urls {
            guard rawExtension(of: url) == "bin", !url.hasDirectoryPath else {
                result.append(url)
                continue
            }
            let cue = cueURL(for: url)
            if given.contains(cue.standardizedFileURL.path.lowercased()) { continue }
            result.append(cueExists(cue) ? cue : url)
        }
        return result
    }

    private static func cueURL(for bin: URL) -> URL {
        bin.deletingPathExtension().appendingPathExtension("cue")
    }
}
