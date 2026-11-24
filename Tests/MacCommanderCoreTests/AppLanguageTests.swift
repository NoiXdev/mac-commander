import Foundation
import Testing

@testable import MacCommanderCore

@MainActor
@Suite struct AppLanguageTests {
    @Test func mapsIdentifiersByPrefix() {
        #expect(AppLanguage(languageIdentifier: "de-DE") == .de)
        #expect(AppLanguage(languageIdentifier: "pl") == .pl)
        #expect(AppLanguage(languageIdentifier: "fr-CA") == .fr)
        #expect(AppLanguage(languageIdentifier: "en-GB") == .en)
        #expect(AppLanguage(languageIdentifier: "es") == .system)
        #expect(AppLanguage(languageIdentifier: nil) == .system)
    }

    /// A throwaway defaults domain, removed again when the test ends.
    private func withDomain(_ body: (UserDefaults, String) -> Void) {
        let domain = "dev.noix.MacCommander.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        body(defaults, domain)
    }

    @Test func systemRemovesTheKeyAndOthersWriteIt() {
        withDomain { defaults, domain in
            let setting = AppLanguageSetting(defaults: defaults, domain: domain)
            #expect(setting.current == .system)

            setting.current = .de
            #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == ["de"])
            #expect(setting.current == .de)

            setting.current = .system
            #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
            #expect(setting.current == .system)
        }
    }

    @Test func readsAChoiceMadeInSystemSettings() {
        withDomain { defaults, domain in
            defaults.setPersistentDomain(["AppleLanguages": ["pl-PL"]], forName: domain)
            #expect(AppLanguageSetting(defaults: defaults, domain: domain).current == .pl)
        }
    }

    @Test func nativeNamesAreNotTranslated() {
        L10n.$localeOverride.withValue("de") {
            #expect(AppLanguage.en.nativeName == "English")
            #expect(AppLanguage.de.nativeName == "Deutsch")
            #expect(AppLanguage.fr.nativeName == "Français")
            #expect(AppLanguage.pl.nativeName == "Polski")
            #expect(AppLanguage.system.nativeName == "System")
        }
    }

    @Test func localeCodes() {
        #expect(AppLanguage.system.localeCode == nil)
        #expect(AppLanguage.allCases.dropFirst().map(\.localeCode) == ["en", "de", "fr", "pl"])
    }
}
