import Foundation

/// Name matching shared by the search engines: a substring match that ignores case and diacritics.
public enum SearchPattern {
    /// Whether `name` contains `text` (trimmed), ignoring case and diacritics. Blank text matches nothing.
    public static func matches(_ name: String, text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// `text` with the `LIKE` wildcards `*` and `?`, the escape character `\` and the single quote `'`
    /// escaped by a backslash, so they match literally. `NSMetadataQuery` puts the value into a single-quoted
    /// MDQuery string without escaping `'` itself; `\'` still matches a literal `'` under `NSPredicate`.
    public static func likeEscaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\*?'".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
