import Foundation

/// One file, folder or symlink inside an archive.
public struct ArchiveEntry: Sendable, Equatable {
    /// Inner path relative to the archive root, "/"-separated, in the archive's original Unicode form.
    public let path: String
    public let isDirectory: Bool
    /// Symlinks are listed as files (never followed into).
    public let isSymlink: Bool
    /// Uncompressed size; nil for folders or when the archive doesn't say.
    public let size: Int64?
    public let modified: Date?
}

/// The folder tree of an archive, built from a `bsdtar -tv` listing.
public struct ArchiveIndex: Sendable {
    /// Folder key → (child key → entry). Keys are NFC-normalized inner paths / names, so the NFD and
    /// NFC spellings of a name are one entry; "" is the root.
    private var folders: [String: [String: ArchiveEntry]] = ["": [:]]

    /// Parses `env LC_ALL=C TZ=UTC bsdtar -tvf archive` output: lines like
    /// `-rw-r--r--  0 user  group  3 Nov 17 17:42 name` (or `… Jan  2  2020 name` for older entries).
    /// Each line is anchored on `<size> <Mon> <dd> <HH:MM|yyyy> ` after the mode, so owner and group
    /// may contain spaces. Dates are UTC with minute precision; a year-only date means 00:00 that day,
    /// a time-only date means the most recent such day not after `now` (+1 day of slack).
    /// Unsafe names (absolute, containing "..") are dropped, parent folders missing from the listing
    /// are synthesized, and for duplicate names the last line wins.
    public init(listing: String, now: Date = Date()) {
        let currentYear = Self.utcYear(of: now)
        var text = listing
        text.withUTF8 { bytes in
            var lineStart = 0
            for i in 0...bytes.count where i == bytes.count || bytes[i] == UInt8(ascii: "\n") {
                if i > lineStart {
                    parseLine(
                        UnsafeBufferPointer(rebasing: bytes[lineStart..<i]),
                        currentYear: currentYear, now: now)
                }
                lineStart = i + 1
            }
        }
    }

    /// Entries directly inside `folder` ("" = root), sorted by path; nil when there is no such folder.
    public func entries(in folder: String) -> [ArchiveEntry]? {
        let key = Self.key(folder.split(separator: "/").joined(separator: "/"))
        return folders[key]?.values.sorted { $0.path < $1.path }
    }

    /// True when `folder` ("" = root) is a folder of the archive. A dictionary lookup, unlike `entries(in:)`,
    /// which sorts the folder's entries.
    public func containsFolder(_ folder: String) -> Bool {
        folders[Self.key(folder.split(separator: "/").joined(separator: "/"))] != nil
    }

    /// Number of distinct entries, including synthesized folders.
    public var entryCount: Int {
        folders.values.reduce(0) { $0 + $1.count }
    }

    // MARK: Parsing

    private static let space = UInt8(ascii: " ")
    private static let months: [[UInt8]] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ].map { Array($0.utf8) }

    private mutating func parseLine(_ line: UnsafeBufferPointer<UInt8>, currentYear: Int, now: Date) {
        // Space-separated tokens as index ranges, collected until the date anchor is found.
        var tokens: [Range<Int>] = []
        var i = 0
        var anchor: (sizeToken: Int, nameStart: Int)?
        while i < line.count {
            while i < line.count && line[i] == Self.space { i += 1 }
            guard i < line.count else { break }
            let start = i
            while i < line.count && line[i] != Self.space { i += 1 }
            tokens.append(start..<i)
            // Anchor: tokens[n-4] size, [n-3] month, [n-2] day, [n-1] time/year; mode is token 0.
            let n = tokens.count
            if n >= 5, i < line.count,
               Self.isDigits(line, tokens[n - 4]),
               Self.month(line, tokens[n - 3]) != nil,
               tokens[n - 2].count <= 2, Self.isDigits(line, tokens[n - 2]),
               Self.isTimeOrYear(line, tokens[n - 1]) {
                anchor = (n - 4, i + 1)
                break
            }
        }
        guard let anchor, anchor.nameStart < line.count else { return }

        let modeChar = line[tokens[0].lowerBound]
        let isDirectory = modeChar == UInt8(ascii: "d")
        let isSymlink = modeChar == UInt8(ascii: "l")
        // Hard links (`h…`, listed as "name link to target", size 0) are regular files.
        let isHardlink = modeChar == UInt8(ascii: "h")
        var nameEnd = line.count
        var hardlinkTarget: [String]?
        if isSymlink, let arrow = Self.firstOccurrence(of: Self.symlinkSeparator, in: line, from: anchor.nameStart) {
            nameEnd = arrow
        } else if isHardlink,
                  let link = Self.firstOccurrence(of: Self.hardlinkSeparator, in: line, from: anchor.nameStart) {
            nameEnd = link
            hardlinkTarget = Self.components(
                Self.unescape(line[(link + Self.hardlinkSeparator.count)..<line.count]))
        }
        var size = Self.number(line, tokens[anchor.sizeToken]).map(Int64.init)
        if isHardlink {
            // The listing says 0; the real size is the target's, when it was listed earlier.
            size = hardlinkTarget.flatMap { entry(at: $0) }.flatMap { $0.isDirectory ? nil : $0.size }
        }
        let modified = Self.date(
            line, month: tokens[anchor.sizeToken + 1], day: tokens[anchor.sizeToken + 2],
            timeOrYear: tokens[anchor.sizeToken + 3], currentYear: currentYear, now: now)

        guard let components = Self.components(Self.unescape(line[anchor.nameStart..<nameEnd])) else { return }
        insert(components, entry: ArchiveEntry(
            path: components.joined(separator: "/"),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: isDirectory ? nil : size,
            modified: modified))
    }

    /// Safe path components of a listed name: "." components and slashes dropped; nil for an empty,
    /// absolute or ".."-containing name.
    private static func components(_ name: String) -> [String]? {
        guard !name.hasPrefix("/") else { return nil }
        var components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        components.removeAll { $0 == "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components
    }

    /// The entry already indexed at `components`, if any.
    private func entry(at components: [String]) -> ArchiveEntry? {
        let parent = Self.key(components.dropLast().joined(separator: "/"))
        return folders[parent]?[Self.key(components[components.count - 1])]
    }

    private static func isDigits(_ line: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Bool {
        !range.isEmpty && range.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(line[$0]) }
    }

    private static func number(_ line: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int? {
        guard isDigits(line, range), range.count <= 18 else { return nil }
        return range.reduce(0) { $0 * 10 + Int(line[$1] - UInt8(ascii: "0")) }
    }

    /// 1...12 for "Jan"..."Dec".
    private static func month(_ line: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int? {
        guard range.count == 3 else { return nil }
        let token = Array(line[range])
        return months.firstIndex(of: token).map { $0 + 1 }
    }

    private static func isTimeOrYear(_ line: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Bool {
        if range.count == 4 { return isDigits(line, range) }
        if range.count == 5, line[range.lowerBound + 2] == UInt8(ascii: ":") {
            return isDigits(line, range.lowerBound..<range.lowerBound + 2)
                && isDigits(line, range.lowerBound + 3..<range.upperBound)
        }
        return false
    }

    private static let symlinkSeparator = Array(" -> ".utf8)
    private static let hardlinkSeparator = Array(" link to ".utf8)

    /// Index of the first occurrence of `pattern` in `line` at or after `start`.
    private static func firstOccurrence(
        of pattern: [UInt8], in line: UnsafeBufferPointer<UInt8>, from start: Int
    ) -> Int? {
        var i = start
        while i + pattern.count <= line.count {
            if line[i] == pattern[0], (1..<pattern.count).allSatisfy({ line[i + $0] == pattern[$0] }) {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func date(
        _ line: UnsafeBufferPointer<UInt8>, month monthRange: Range<Int>, day dayRange: Range<Int>,
        timeOrYear: Range<Int>, currentYear: Int, now: Date
    ) -> Date? {
        guard let month = month(line, monthRange), let day = number(line, dayRange) else { return nil }
        if timeOrYear.count == 4 {
            guard let year = number(line, timeOrYear) else { return nil }
            return utcDate(year: year, month: month, day: day, minutes: 0)
        }
        guard let hours = number(line, timeOrYear.lowerBound..<timeOrYear.lowerBound + 2),
              let minutes = number(line, timeOrYear.lowerBound + 3..<timeOrYear.upperBound)
        else { return nil }
        let date = utcDate(year: currentYear, month: month, day: day, minutes: hours * 60 + minutes)
        // bsdtar shows a time (not a year) for recent entries; one "in the future" is from last year.
        if date > now.addingTimeInterval(86_400) {
            return utcDate(year: currentYear - 1, month: month, day: day, minutes: hours * 60 + minutes)
        }
        return date
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
    private static func utcDate(year: Int, month: Int, day: Int, minutes: Int) -> Date {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + minutes * 60))
    }

    private static func utcYear(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.year, from: date)
    }

    private mutating func insert(_ components: [String], entry: ArchiveEntry) {
        // Make sure every ancestor exists as a folder (zips often list only files).
        var parentKey = ""
        for depth in 0..<(components.count - 1) {
            let childKey = Self.key(components[depth])
            let folderKey = parentKey.isEmpty ? childKey : parentKey + "/" + childKey
            if folders[folderKey] == nil || folders[parentKey]?[childKey]?.isDirectory != true {
                folders[parentKey, default: [:]][childKey] = ArchiveEntry(
                    path: components[0...depth].joined(separator: "/"),
                    isDirectory: true, isSymlink: false, size: nil, modified: nil)
                if folders[folderKey] == nil { folders[folderKey] = [:] }
            }
            parentKey = folderKey
        }
        let childKey = Self.key(components[components.count - 1])
        folders[parentKey, default: [:]][childKey] = entry
        if entry.isDirectory {
            let folderKey = parentKey.isEmpty ? childKey : parentKey + "/" + childKey
            if folders[folderKey] == nil { folders[folderKey] = [:] }
        }
    }

    /// Decodes bsdtar's listing escapes: `\ooo` octal bytes, `\\`, and `\n`, `\t`, `\r`, `\a`, `\b`,
    /// `\f`, `\v`; the bytes are then read as UTF-8.
    private static func unescape(_ raw: Slice<UnsafeBufferPointer<UInt8>>) -> String {
        let backslash = UInt8(ascii: "\\")
        guard raw.contains(backslash) else { return String(decoding: raw, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            let byte = raw[i]
            if byte == backslash, i + 1 < raw.endIndex {
                if i + 3 < raw.endIndex,
                   let a = octal(raw[i + 1]), let b = octal(raw[i + 2]), let c = octal(raw[i + 3]) {
                    out.append(UInt8(truncatingIfNeeded: a << 6 | b << 3 | c))
                    i += 4
                    continue
                }
                let next = raw[i + 1]
                switch next {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "a"): out.append(0x07)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "v"): out.append(0x0B)
                default: out.append(next)  // "\\" and anything unknown
                }
                i += 2
                continue
            }
            out.append(byte)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func octal(_ byte: UInt8) -> Int? {
        (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) ? Int(byte - UInt8(ascii: "0")) : nil
    }

    /// Lookup key for a name or path: Unicode NFC, so canonically equivalent spellings match.
    static func key(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping
    }
}
