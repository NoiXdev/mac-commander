import Foundation

public enum NameGenerator {
    /// Returns `base[.ext]`, or `base 2[.ext]`, `base 3[.ext]`, … — the first name not present in `directory`.
    public static func uniqueName(
        base: String, pathExtension: String?, in directory: URL, fileManager: FileManager = .default
    ) -> String {
        firstFreeName(base: base, pathExtension: pathExtension, startingAt: 1, in: directory, fileManager: fileManager)
    }

    /// Finder-style duplicate name: `name copy.ext`, `name copy 2.ext`, … Always a copy name, even if `name` is free.
    /// Duplicating a copy continues its numbering (`report copy.txt` → `report copy 2.txt`) instead of stacking.
    /// `copyWord` is written into the new name. Both it and the English "copy" count as a copy when continuing.
    public static func copyName(
        for name: String, isDirectory: Bool, in directory: URL,
        copyWord: String = L10n.string("name.copySuffix", "copy"), fileManager: FileManager = .default
    ) -> String {
        let (stem, ext) = split(name, isDirectory: isDirectory)
        var base = stem
        var start = 1
        let words = copyWord == "copy" ? ["copy"] : [copyWord, "copy"]
        let alternatives = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        if let range = stem.range(of: " (?:\(alternatives))( [0-9]+)?$", options: .regularExpression) {
            let matched = stem[range].dropFirst()
            let word = words.first { matched.hasPrefix($0) } ?? copyWord
            let suffix = matched.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            // A number at or beyond Int.max can't be continued: the stem then counts as a plain name.
            if suffix.isEmpty {
                base = String(stem[..<range.lowerBound])
                start = 2
            } else if let n = Int(suffix), n < Int.max {
                base = String(stem[..<range.lowerBound])
                start = max(n + 1, 2)
            }
        }
        return firstFreeName(
            base: base + " " + copyWord, pathExtension: ext, startingAt: start, in: directory, fileManager: fileManager)
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
