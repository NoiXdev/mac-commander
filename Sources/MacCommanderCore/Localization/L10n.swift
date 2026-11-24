import Foundation

/// Looks up user-visible text in `Resources/{en,de,fr,pl}.lproj`. Every call site passes a key and its English
/// text as plain literals. The English text is the fallback, and a test checks that it matches `en.lproj`.
///
/// Plurals live in `Localizable.stringsdict`. Each entry has one variable, the count, and its format is only that
/// variable (`%#@count@`), so each form holds the whole sentence and can use the other arguments too.
public enum L10n {
    private final class BundleToken {}

    /// Core's resource bundle, found by hand instead of with `Bundle.module`, which calls `fatalError` when the
    /// bundle is missing. If it's missing here, every lookup returns its English text.
    public static let bundle: Bundle = {
        let name = "MacCommander_MacCommanderCore.bundle"
        let directories = [
            Bundle.main.bundleURL,
            Bundle.main.resourceURL,  // the app: `scripts/build-app.sh` copies it into Contents/Resources
            Bundle.main.executableURL?.deletingLastPathComponent(),
            // `swift test`: Core is linked into the .xctest bundle, and the resource bundle sits next to it.
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
        ]
        for case let directory? in directories {
            if let bundle = Bundle(url: directory.appending(path: name)) { return bundle }
        }
        return .main
    }()

    /// Resolves every lookup in this one language (`"de"` …) instead of the user's. Tests set it, the app never
    /// does: the app's language is the system's per-app language setting.
    @TaskLocal public static var localeOverride: String?

    public static func string(_ key: String, _ english: String) -> String {
        lookup(key) ?? english
    }

    /// `string(_:_:)` with its placeholders filled. Use positional placeholders (`%1$@`) when there are several,
    /// so a translation can reorder them.
    public static func format(_ key: String, _ english: String, _ args: any CVarArg...) -> String {
        String(format: string(key, english), locale: locale, arguments: args)
    }

    /// A text that depends on `count`. The count is the first format argument and `args` follow, so a form reads
    /// `%1$lld` for the count and `%2$@` for the first of `args`. `one` and `other` are the English forms.
    public static func plural(_ key: String, count: Int, one: String, other: String, _ args: any CVarArg...)
        -> String
    {
        let format = lookup(key) ?? (count == 1 ? one : other)
        return String(format: format, locale: locale, arguments: [count] + args)
    }

    /// The table's value, or `nil` if the key isn't there. Asked with no default, the bundle answers the key itself.
    private static func lookup(_ key: String) -> String? {
        let value = table.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? nil : value
    }

    /// The override language's `.lproj`, or the whole bundle, which picks the user's language.
    private static var table: Bundle {
        guard let code = localeOverride, let path = bundle.path(forResource: code, ofType: "lproj"),
            let lproj = Bundle(path: path)
        else { return bundle }
        return lproj
    }

    /// The locale of the language the text comes from. `.stringsdict` picks its plural form by this locale's
    /// rules, so it has to match the table: Polish forms need Polish rules.
    private static var locale: Locale {
        Locale(identifier: localeOverride ?? bundle.preferredLocalizations.first ?? "en")
    }
}
