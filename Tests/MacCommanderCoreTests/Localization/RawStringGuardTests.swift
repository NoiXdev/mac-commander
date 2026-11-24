import Foundation
import Testing

/// Guards the finished localization: user-visible text reaches the screen through `L10n` and the tables, never as
/// a bare literal. The tests read `Sources/` from disk, like `SourceKeyTests`.
@Suite struct RawStringGuardTests {
    /// Literals that stay as they are on purpose. `file` is a path suffix, `literal` the text between the quotes.
    /// An entry that no longer matches anything fails `allowListHasNoStaleEntries`.
    ///
    /// Empty today. The literals left on purpose are not shown by any banned call: the native language names
    /// (`AppLanguage.nativeName`), the ShortcutRecorder key labels and `ConnectToServerSheet.addressExample` are
    /// plain values, and `Text("")`, `TextField("", …)` and `"--"` have no letter.
    private static let allowList: [(file: String, literal: String, reason: String)] = []

    /// A SwiftUI view whose first argument is shown to the user.
    private static var viewPattern: Regex<(Substring, prefix: Substring)> {
        #/(?<prefix>[\w.]*)(?:Text|Button|Toggle|Label|Section|Picker|Menu|CommandMenu|LabeledContent|TextField|SecureField)(?=\s*\()/#
    }

    /// Modifiers, AppKit calls and AppKit properties that show their string to the user.
    private static var otherPattern: Regex<Substring> {
        #/NSMenuItem\(title:|addButton\(withTitle:|\.(?:help|navigationTitle|alert|confirmationDialog)(?=\s*\()|(?:messageText|informativeText)\s*=/#
    }

    @Test func noStringLocalizedLeft() throws {
        for file in try LocalizationFiles.sourceFiles() {
            let source = LocalizationFiles.withoutCommentLines(try String(contentsOf: file, encoding: .utf8))
            #expect(!source.contains("String(localized:"), "\(relativePath(file)) uses String(localized:)")
        }
    }

    @Test func noBareUILiterals() throws {
        let found = try Self.bareLiterals().filter { hit in
            !Self.allowList.contains { hit.file.hasSuffix($0.file) && hit.literal == $0.literal }
        }
        #expect(found.map(\.description) == [], "user-visible text must go through L10n")
    }

    @Test func allowListHasNoStaleEntries() throws {
        let hits = try Self.bareLiterals()
        for entry in Self.allowList {
            #expect(
                hits.contains { $0.file.hasSuffix(entry.file) && $0.literal == entry.literal },
                "stale allow-list entry: \(entry.file) \"\(entry.literal)\" (\(entry.reason))")
        }
    }

    // MARK: - Scanning

    private struct Hit: CustomStringConvertible {
        let file: String
        let line: Int
        let literal: String
        var description: String { "\(file):\(line) \"\(literal)\"" }
    }

    private func relativePath(_ file: URL) -> String {
        String(file.path.dropFirst(LocalizationFiles.repoRoot.path.count + 1))
    }

    /// Every banned call or assignment followed by a string literal that has a letter outside its interpolations.
    private static func bareLiterals() throws -> [Hit] {
        var hits: [Hit] = []
        for file in try LocalizationFiles.sourceFiles() {
            let path = String(file.path.dropFirst(LocalizationFiles.repoRoot.path.count + 1))
            let source = LocalizationFiles.withoutCommentLines(try String(contentsOf: file, encoding: .utf8))
            let characters = Array(source)
            func check(_ range: Range<String.Index>) {
                var index = source.distance(from: source.startIndex, to: range.upperBound)
                // A view or modifier name is followed by `(`; the others already consumed everything up to the literal.
                let name = source[range]
                if !name.hasSuffix(":") && !name.hasSuffix("=") {
                    while index < characters.count, characters[index] == " " { index += 1 }
                    guard index < characters.count, characters[index] == "(" else { return }
                    index += 1
                }
                while index < characters.count, characters[index] == " " || characters[index] == "\n" { index += 1 }
                guard index < characters.count, characters[index] == "\"" else { return }
                let literal = literalBody(characters, after: index)
                if literal.hasLetter {
                    let line = characters[..<index].count(where: { $0 == "\n" }) + 1
                    hits.append(Hit(file: path, line: line, literal: literal.body))
                }
            }
            // A view name stands alone: `MyText(` and `Foo.Button(` are other things.
            for match in source.matches(of: viewPattern) where match.prefix.isEmpty || match.prefix == "SwiftUI." {
                check(match.range)
            }
            for match in source.matches(of: otherPattern) { check(match.range) }
        }
        return hits
    }

    /// The text of the string literal whose opening quote is at `quote`, and whether it has a letter outside the
    /// `\( … )` interpolations.
    private static func literalBody(_ characters: [Character], after quote: Int) -> (body: String, hasLetter: Bool) {
        var body = ""
        var hasLetter = false
        var index = quote + 1
        while index < characters.count, characters[index] != "\"" {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                if characters[index + 1] == "(" {
                    var depth = 1
                    body += "\\("
                    index += 2
                    while index < characters.count, depth > 0 {
                        if characters[index] == "(" { depth += 1 }
                        if characters[index] == ")" { depth -= 1 }
                        body.append(characters[index])
                        index += 1
                    }
                    continue
                }
                body.append(character)
                body.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "\n" { break }
            if character.isLetter { hasLetter = true }
            body.append(character)
            index += 1
        }
        return (body, hasLetter)
    }
}
