import Foundation

/// A format the Convert ▸ menu can produce.
public enum ConvertTarget: String, CaseIterable, Sendable, Hashable {
    case jpeg, png, heic, tiff, m4a, wav, aiff, mp3, flac, mp4H264, movHEVC, mp4FFmpeg,
         docx, rtf, txt, html, pdf, zip, tarGz, sevenZip, iso

    public var label: String {
        switch self {
        case .jpeg: L10n.string("convert.target.jpeg", "JPEG Image")
        case .png: L10n.string("convert.target.png", "PNG Image")
        case .heic: L10n.string("convert.target.heic", "HEIC Image")
        case .tiff: L10n.string("convert.target.tiff", "TIFF Image")
        case .m4a: L10n.string("convert.target.m4a", "M4A Audio (AAC)")
        case .wav: L10n.string("convert.target.wav", "WAV Audio")
        case .aiff: L10n.string("convert.target.aiff", "AIFF Audio")
        case .mp3: L10n.string("convert.target.mp3", "MP3 Audio")
        case .flac: L10n.string("convert.target.flac", "FLAC Audio")
        case .mp4H264: L10n.string("convert.target.mp4H264", "MP4 Video (H.264)")
        case .movHEVC: L10n.string("convert.target.movHEVC", "MOV Video (HEVC)")
        case .mp4FFmpeg: L10n.string("convert.target.mp4FFmpeg", "MP4 Video")
        case .docx: L10n.string("convert.target.docx", "Word Document (DOCX)")
        case .rtf: L10n.string("convert.target.rtf", "Rich Text (RTF)")
        case .txt: L10n.string("convert.target.txt", "Plain Text (TXT)")
        case .html: L10n.string("convert.target.html", "Web Page (HTML)")
        case .pdf: L10n.string("convert.target.pdf", "PDF (simple layout)")
        case .zip: L10n.string("convert.target.zip", "ZIP Archive")
        case .tarGz: L10n.string("convert.target.tarGz", "TAR.GZ Archive")
        case .sevenZip: L10n.string("convert.target.sevenZip", "7-Zip Archive")
        case .iso: L10n.string("convert.target.iso", "Disc Image (ISO)")
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        case .m4a: "m4a"
        case .wav: "wav"
        case .aiff: "aiff"
        case .mp3: "mp3"
        case .flac: "flac"
        case .mp4H264: "mp4"
        case .movHEVC: "mov"
        case .mp4FFmpeg: "mp4"
        case .docx: "docx"
        case .rtf: "rtf"
        case .txt: "txt"
        case .html: "html"
        case .pdf: "pdf"
        case .zip: "zip"
        case .tarGz: "tar.gz"
        case .sevenZip: "7z"
        case .iso: "iso"
        }
    }

    /// Targets only the external ffmpeg binary can write.
    public var needsFFmpeg: Bool {
        switch self {
        case .mp3, .flac, .mp4FFmpeg: true
        default: false
        }
    }
}
