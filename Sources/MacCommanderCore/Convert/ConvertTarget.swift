import Foundation

/// A format the Convert ▸ menu can produce.
public enum ConvertTarget: String, CaseIterable, Sendable, Hashable {
    case jpeg, png, heic, tiff, m4a, wav, aiff, mp3, flac, mp4H264, movHEVC, mp4FFmpeg,
         docx, rtf, txt, html, pdf, zip, tarGz, sevenZip, iso

    public var label: String {
        switch self {
        case .jpeg: String(localized: "JPEG Image")
        case .png: String(localized: "PNG Image")
        case .heic: String(localized: "HEIC Image")
        case .tiff: String(localized: "TIFF Image")
        case .m4a: String(localized: "M4A Audio (AAC)")
        case .wav: String(localized: "WAV Audio")
        case .aiff: String(localized: "AIFF Audio")
        case .mp3: String(localized: "MP3 Audio")
        case .flac: String(localized: "FLAC Audio")
        case .mp4H264: String(localized: "MP4 Video (H.264)")
        case .movHEVC: String(localized: "MOV Video (HEVC)")
        case .mp4FFmpeg: String(localized: "MP4 Video")
        case .docx: String(localized: "Word Document (DOCX)")
        case .rtf: String(localized: "Rich Text (RTF)")
        case .txt: String(localized: "Plain Text (TXT)")
        case .html: String(localized: "Web Page (HTML)")
        case .pdf: String(localized: "PDF (simple layout)")
        case .zip: String(localized: "ZIP Archive")
        case .tarGz: String(localized: "TAR.GZ Archive")
        case .sevenZip: String(localized: "7-Zip Archive")
        case .iso: String(localized: "Disc Image (ISO)")
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
