import Foundation

public enum NameGenerator {
    /// Returns `base[.ext]`, or `base 2[.ext]`, `base 3[.ext]`, … — the first name not present in `directory`.
    public static func uniqueName(
        base: String, pathExtension: String?, in directory: URL, fileManager: FileManager = .default
    ) -> String {
        firstFreeName(base: base, pathExtension: pathExtension, startingAt: 1, in: directory, fileManager: fileManager)
    }

    /// Finder's English duplicate pattern, recognised in every language so a copy made before a language switch
    /// still numbers on.
    public static let englishCopyPattern = "%@ copy"

    /// Finder-style duplicate name: `name copy.ext`, `name copy 2.ext`, … Always a copy name, even if `name` is free.
    /// Duplicating a copy continues its numbering (`report copy.txt` → `report copy 2.txt`) instead of stacking.
    /// `copyPattern` puts the copy word around the base name, `%@` standing for the base: "%@ copy", or
    /// "%@-kopia" in Polish. A number then follows with a space, as in Finder. Both it and the English pattern
    /// count as a copy when continuing.
    public static func copyName(
        for name: String, isDirectory: Bool, in directory: URL,
        copyPattern: String = L10n.string("name.copy", "%@ copy"), fileManager: FileManager = .default
    ) -> String {
        let (stem, ext) = split(name, isDirectory: isDirectory)
        // A pattern without `%@` can't hold a name: Finder's English one is used instead.
        let english = CopyPattern(englishCopyPattern)!
        let pattern = CopyPattern(copyPattern) ?? english
        let patterns = pattern.format == english.format ? [pattern] : [pattern, english]
        var base = stem
        var start = 1
        if let match = patterns.lazy.compactMap({ $0.match(stem) }).first {
            // A number at or beyond Int.max can't be continued: the stem then counts as a plain name.
            if let number = match.number {
                if let n = Int(number), n < Int.max {
                    base = match.base
                    start = max(n + 1, 2)
                }
            } else {
                base = match.base
                start = 2
            }
        }
        return firstFreeName(
            base: pattern.apply(base), pathExtension: ext, startingAt: start, in: directory, fileManager: fileManager)
    }

    /// A duplicate pattern split at its `%@` (or `%1$@`) into the literal text before and after the base name.
    private struct CopyPattern {
        let format: String
        let prefix: String
        let suffix: String
        private let regex: NSRegularExpression

        init?(_ format: String) {
            guard let placeholder = format.range(of: "%1$@") ?? format.range(of: "%@") else { return nil }
            self.format = format
            prefix = format[..<placeholder.lowerBound].replacingOccurrences(of: "%%", with: "%")
            suffix = format[placeholder.upperBound...].replacingOccurrences(of: "%%", with: "%")
            // The text around the base is escaped, so a word with `.`, `+` or `(` in it matches only itself.
            let before = NSRegularExpression.escapedPattern(for: prefix)
            let after = NSRegularExpression.escapedPattern(for: suffix)
            // A name may hold a line break, which `.` has to match too.
            guard
                let regex = try? NSRegularExpression(
                    pattern: "^\(before)(.*)\(after)(?: ([0-9]+))?$", options: .dotMatchesLineSeparators)
            else { return nil }
            self.regex = regex
        }

        func apply(_ base: String) -> String { prefix + base + suffix }

        /// The base and the number, if `stem` is a copy name made with this pattern.
        func match(_ stem: String) -> (base: String, number: String?)? {
            let range = NSRange(stem.startIndex..., in: stem)
            guard let result = regex.firstMatch(in: stem, range: range),
                let base = Range(result.range(at: 1), in: stem)
            else { return nil }
            let number = Range(result.range(at: 2), in: stem).map { String(stem[$0]) }
            return (String(stem[base]), number)
        }
    }

    /// Finder "Keep Both" name: `name` itself when free, otherwise `name 2.ext`, `name 3.ext`, …
    /// A trailing ` <n>` on the stem continues from `n + 1`.
    public static func keepBothName(
        for name: String, isDirectory: Bool, in directory: URL, fileManager: FileManager = .default
    ) -> String {
        if !exists(name, in: directory, fileManager: fileManager) { return name }
        let (stem, ext) = split(name, isDirectory: isDirectory)
        var base = stem
        var start = 2
        if let range = stem.range(of: #" [0-9]+$"#, options: .regularExpression),
            let n = Int(stem[range].dropFirst()), n >= 2, n < Int.max
        {
            base = String(stem[..<range.lowerBound])
            start = n + 1
        }
        return firstFreeName(base: base, pathExtension: ext, startingAt: start, in: directory, fileManager: fileManager)
    }

    /// Extension is split only for non-directories with a non-empty extension (`.zshrc` has none).
    private static func split(_ name: String, isDirectory: Bool) -> (stem: String, ext: String?) {
        let ns = name as NSString
        guard !isDirectory, !ns.pathExtension.isEmpty else { return (name, nil) }
        return (ns.deletingPathExtension, ns.pathExtension)
    }

    /// attributesOfItem uses lstat, so dangling symlinks count as taken.
    private static func exists(_ name: String, in directory: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)) != nil
    }

    /// First free of `base[.ext]` (n == 1), `base 2[.ext]`, … beginning at `start`.
    private static func firstFreeName(
        base: String, pathExtension: String?, startingAt start: Int, in directory: URL, fileManager: FileManager
    ) -> String {
        func name(_ n: Int) -> String {
            let stem = n == 1 ? base : "\(base) \(n)"
            guard let pathExtension else { return stem }
            return "\(stem).\(pathExtension)"
        }
        var n = start
        // Stops at Int.max instead of trapping; callers never write over an existing item anyway.
        while n < Int.max, exists(name(n), in: directory, fileManager: fileManager) { n += 1 }
        return name(n)
    }
}
