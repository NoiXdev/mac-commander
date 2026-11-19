import Foundation

public enum DiscImageError: Error, Equatable, Sendable {
    case noDataTrack, multipleDataFiles, missingBin(String), sizeMismatch, unreadable(String)
    /// The source isn't a `.cue` file (its CUE sheet went missing after the menu was built).
    case notCueSheet(String)
}

extension DiscImageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noDataTrack: String(localized: "The CUE sheet has no data track.")
        case .multipleDataFiles: String(localized: "The data track spans several BIN files.")
        case .missingBin(let name): String(localized: "“\(name)” is missing.")
        case .sizeMismatch: String(localized: "The BIN file’s size doesn’t match its sector size.")
        case .unreadable(let name): String(localized: "“\(name)” couldn’t be read.")
        case .notCueSheet(let name): String(localized: "“\(name)” needs its CUE sheet (.cue) beside it.")
        }
    }
}

/// The parts of a CUE sheet needed to turn a BIN/CUE image into an ISO.
public struct CueSheet: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case mode1_2048, mode1_2352, mode2_2336, mode2_2352, audio

        public var isData: Bool { self != .audio }

        /// Bytes per sector in the BIN file.
        public var sectorSize: Int {
            switch self {
            case .mode1_2048: 2048
            case .mode2_2336: 2336
            case .mode1_2352, .mode2_2352, .audio: 2352
            }
        }

        /// Offset of the 2048 user-data bytes inside a sector.
        public var dataOffset: Int {
            switch self {
            case .mode1_2048, .audio: 0
            case .mode1_2352: 16
            case .mode2_2352: 24
            case .mode2_2336: 8
            }
        }
    }

    public struct Track: Equatable, Sendable {
        public let number: Int
        public let mode: Mode
        public let file: String
        /// `mm*60*75 + ss*75 + ff`
        public let index01Frames: Int
        /// The next track's INDEX 00 (else 01) in the same file; nil means to the end of the file.
        public let nextStartFrames: Int?
    }

    public let tracks: [Track]

    public var audioTrackCount: Int { tracks.filter { $0.mode == .audio }.count }

    public static func parse(_ text: String) throws(DiscImageError) -> CueSheet {
        struct Draft { var number: Int; var mode: Mode; var file: String; var index00: Int?; var index01: Int? }
        var drafts: [Draft] = []
        var currentFile: String?
        var skipping = false  // inside a TRACK with an unsupported mode

        for rawLine in text.components(separatedBy: .newlines) {
            let words = tokens(rawLine)
            guard let keyword = words.first?.uppercased() else { continue }
            switch keyword {
            case "FILE":
                if words.count >= 2 { currentFile = words[1] }
            case "TRACK":
                guard words.count >= 3, let number = Int(words[1]), let file = currentFile,
                      let mode = mode(words[2].uppercased())
                else { skipping = true; continue }
                skipping = false
                drafts.append(Draft(number: number, mode: mode, file: file))
            case "INDEX":
                guard !skipping, !drafts.isEmpty, words.count >= 3, let index = Int(words[1]),
                      let frames = frames(words[2])
                else { continue }
                if index == 0 { drafts[drafts.count - 1].index00 = frames }
                if index == 1 { drafts[drafts.count - 1].index01 = frames }
            default:
                continue
            }
        }

        let usable = drafts.filter { $0.index01 != nil }
        var tracks: [Track] = []
        for (position, draft) in usable.enumerated() {
            var next: Int?
            if position + 1 < usable.count, usable[position + 1].file == draft.file {
                next = usable[position + 1].index00 ?? usable[position + 1].index01
            }
            tracks.append(Track(
                number: draft.number, mode: draft.mode, file: draft.file,
                index01Frames: draft.index01 ?? 0, nextStartFrames: next))
        }
        guard tracks.contains(where: { $0.mode.isData }) else { throw .noDataTrack }
        return CueSheet(tracks: tracks)
    }

    /// Splits a line into words; a double-quoted run (spaces allowed) is one word.
    private static func tokens(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var started = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                started = true
            } else if character.isWhitespace && !quoted {
                if started { result.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { result.append(current) }
        return result
    }

    private static func mode(_ name: String) -> Mode? {
        switch name {
        case "MODE1/2048": .mode1_2048
        case "MODE1/2352": .mode1_2352
        case "MODE2/2336": .mode2_2336
        case "MODE2/2352": .mode2_2352
        case "AUDIO": .audio
        default: nil
        }
    }

    private static func frames(_ timestamp: String) -> Int? {
        let parts = timestamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 60 * 75 + parts[1] * 75 + parts[2]
    }
}
