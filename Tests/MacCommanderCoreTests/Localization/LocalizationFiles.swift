import Foundation

/// The localization tables and the `L10n` call sites, read straight from the repo by `#filePath`. The tests check
/// what is in the source tree, not what a build happened to copy.
enum LocalizationFiles {
    static let languages = ["en", "de", "fr", "pl"]

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Localization
        .deletingLastPathComponent()  // MacCommanderCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()

    static let sourcesDirectory = repoRoot.appending(path: "Sources")
    static let resourcesDirectory = repoRoot.appending(path: "Sources/MacCommanderCore/Resources")

    /// `Localizable.strings` of one language, key to value.
    static func strings(_ language: String) throws -> [String: String] {
        let data = try Data(contentsOf: table(language, "Localizable.strings"))
        guard let strings = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { throw Problem("\(language) Localizable.strings is not a table of strings") }
        return strings
    }

    /// `Localizable.stringsdict` of one language, key to entry.
    static func plurals(_ language: String) throws -> [String: PluralEntry] {
        let data = try Data(contentsOf: table(language, "Localizable.stringsdict"))
        guard let entries = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Problem("\(language) Localizable.stringsdict is not a dictionary") }
        return try entries.mapValues { value in
            guard let dictionary = value as? [String: Any], let entry = PluralEntry(dictionary)
            else { throw Problem("\(language) Localizable.stringsdict has an entry with not exactly one variable") }
            return entry
        }
    }

    /// Every Swift file under `Sources/`.
    static func sourceFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        guard !files.isEmpty else { throw Problem("no Swift files under \(sourcesDirectory.path)") }
        return files.sorted { $0.path < $1.path }
    }

    /// Every `L10n.string/format/text/plural` call in `Sources/` whose key and English text are plain literals.
    static func callSites() throws -> [CallSite] {
        try scan().readable
    }

    /// `file:line` of every `L10n` call whose key or English text is not a plain literal, so `callSites()` can't
    /// read it: a variable, an interpolation, or a literal split over lines.
    static func unreadableCallSites() throws -> [String] {
        try scan().unreadable
    }

    /// The placeholders in a value (`%@`, `%lld`, `%1$@`, `%#@count@` …), sorted, so two values can be compared as
    /// multisets. `%%` is a literal percent sign and not counted.
    static func placeholders(in value: String) -> [String] {
        value.replacing("%%", with: "")
            .matches(of: #/%(?:\d+\$)?(?:#@\w+@|\.?\d*(?:ll|l)?[@dfiux])/#)
            .map { String($0.output) }
            .sorted()
    }

    struct Problem: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func table(_ language: String, _ name: String) -> URL {
        resourcesDirectory.appending(path: "\(language).lproj/\(name)")
    }

    private static func scan() throws -> (readable: [CallSite], unreadable: [String]) {
        var readable: [CallSite] = []
        var unreadable: [String] = []
        for file in try sourceFiles() {
            let path = String(file.path.dropFirst(repoRoot.path.count + 1))
            let source = withoutCommentLines(try String(contentsOf: file, encoding: .utf8))
            func line(of index: String.Index) -> Int { source[..<index].count(where: { $0 == "\n" }) + 1 }

            var starts: Set<String.Index> = []
            for match in source.matches(of: singlePattern) {
                starts.insert(match.range.lowerBound)
                readable.append(CallSite(
                    key: String(match.key), english: .text(unescaped(match.english)),
                    file: path, line: line(of: match.range.lowerBound)))
            }
            for match in source.matches(of: pluralPattern) {
                starts.insert(match.range.lowerBound)
                readable.append(CallSite(
                    key: String(match.key), english: .plural(one: unescaped(match.one), other: unescaped(match.other)),
                    file: path, line: line(of: match.range.lowerBound)))
            }
            for match in source.matches(of: anyCallPattern) where !starts.contains(match.range.lowerBound) {
                unreadable.append("\(path):\(line(of: match.range.lowerBound))")
            }
        }
        return (readable, unreadable)
    }

    // A literal is a plain single-line Swift string: no interpolation `\(…)`.
    private static var singlePattern: Regex<(Substring, key: Substring, english: Substring)> {
        #/L10n\.(?:string|format|text)\(\s*"(?<key>[^"\\\n]*)"\s*,\s*"(?<english>(?:[^"\\\n]|\\[^(\n])*)"/#
    }
    private static var pluralPattern: Regex<(Substring, key: Substring, one: Substring, other: Substring)> {
        #/L10n\.plural\(\s*"(?<key>[^"\\\n]*)"\s*,\s*count:[^\n]*?,\s*one:\s*"(?<one>(?:[^"\\\n]|\\[^(\n])*)"\s*,\s*other:\s*"(?<other>(?:[^"\\\n]|\\[^(\n])*)"/#
    }
    private static var anyCallPattern: Regex<Substring> { #/L10n\.(?:string|format|text|plural)\(/# }

    /// Blanks out `//` comment lines, keeping the line count, so an example in a doc comment isn't a call site.
    static func withoutCommentLines(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0 }
            .joined(separator: "\n")
    }

    /// The value of a Swift literal's body: `\"`, `\\`, `\n`, `\t` and `\0` become the character they stand for.
    private static func unescaped(_ literal: Substring) -> String {
        var result = ""
        var characters = literal.makeIterator()
        while let character = characters.next() {
            guard character == "\\", let escaped = characters.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "0": result.append("\0")
            default: result.append(escaped)
            }
        }
        return result
    }
}

/// One `L10n` call in the sources, with the English text it passes.
struct CallSite: CustomStringConvertible {
    enum English: Equatable {
        case text(String)
        case plural(one: String, other: String)
    }

    let key: String
    let english: English
    /// Relative to the repo root.
    let file: String
    let line: Int

    var description: String { "\(file):\(line) \(key)" }
}

/// One `.stringsdict` entry. By convention it has exactly one plural variable, the count, and the format is just
/// that variable (`%#@count@`), so each form holds the whole sentence.
struct PluralEntry {
    /// `NSStringLocalizedFormatKey`.
    let format: String
    let variable: String
    /// Plural category (`one`, `few`, …) to text.
    let forms: [String: String]

    init?(_ dictionary: [String: Any]) {
        guard let format = dictionary["NSStringLocalizedFormatKey"] as? String else { return nil }
        let variables = dictionary.filter { $0.key != "NSStringLocalizedFormatKey" }
        guard variables.count == 1, let variable = variables.first, let rule = variable.value as? [String: Any]
        else { return nil }
        self.format = format
        self.variable = variable.key
        forms = rule.filter { !$0.key.hasPrefix("NSStringFormat") }.compactMapValues { $0 as? String }
    }
}
