import Foundation

/// The language the app shows its text in. `.system` follows the Mac; the others pin the app to one language.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, en, de, fr, pl

    /// The `AppleLanguages` code to store, or nil for `.system` (no override).
    public var localeCode: String? {
        self == .system ? nil : rawValue
    }

    /// The language's own name. It is never translated, so a user who ended up in a language they can't read can
    /// still find theirs. Only "System" is looked up.
    public var nativeName: String {
        switch self {
        case .system: L10n.string("settings.general.language.system", "System")
        case .en: "English"
        case .de: "Deutsch"
        case .fr: "Français"
        case .pl: "Polski"
        }
    }

    /// Maps a language identifier such as `"de-DE"` by its prefix. Nil or an unsupported language is `.system`.
    public init(languageIdentifier: String?) {
        guard let identifier = languageIdentifier else {
            self = .system
            return
        }
        let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? identifier
        self = Self.allCases.first { $0.localeCode == code.lowercased() } ?? .system
    }
}

/// The app's language as macOS stores it: the first `AppleLanguages` entry in the app's own defaults domain. That
/// is the same setting as System Settings ▸ Language & Region ▸ Applications, so the app keeps no copy of it.
@MainActor
public struct AppLanguageSetting {
    private static let key = "AppleLanguages"

    private let defaults: UserDefaults
    private let domain: String

    public init(defaults: UserDefaults = .standard, domain: String) {
        self.defaults = defaults
        self.domain = domain
    }

    /// Reads the stored choice. Writing `.system` removes the key; any other value stores `[code]`.
    public var current: AppLanguage {
        get {
            let languages = defaults.persistentDomain(forName: domain)?[Self.key] as? [String]
            return AppLanguage(languageIdentifier: languages?.first)
        }
        nonmutating set {
            var values = defaults.persistentDomain(forName: domain) ?? [:]
            if let code = newValue.localeCode {
                values[Self.key] = [code]
            } else {
                values.removeValue(forKey: Self.key)
            }
            defaults.setPersistentDomain(values, forName: domain)
        }
    }
}
