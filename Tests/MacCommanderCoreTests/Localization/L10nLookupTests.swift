import Testing

@testable import MacCommanderCore

@Suite struct L10nLookupTests {
    @Test(arguments: [("de", "Darstellung"), ("fr", "Présentation"), ("pl", "Widok")])
    func looksUpTheOverrideLanguage(language: String, title: String) {
        L10n.$localeOverride.withValue(language) {
            #expect(SettingsSection.view.title == title)
        }
    }

    @Test func fallsBackToTheEnglishArgumentForAnUnknownKey() {
        #expect(L10n.string("test.missing", "Fallback") == "Fallback")
        #expect(L10n.format("test.missing", "%1$@ in %2$@", "a", "b") == "a in b")
        #expect(L10n.plural("test.missing", count: 1, one: "%lld thing", other: "%lld things") == "1 thing")
        #expect(L10n.plural("test.missing", count: 2, one: "%lld thing", other: "%lld things") == "2 things")
    }

    @Test(.english) func pluralPicksEnglishForms() {
        #expect(L10n.plural("test.files", count: 1, one: "%lld file", other: "%lld files") == "1 file")
        #expect(L10n.plural("test.files", count: 3, one: "%lld file", other: "%lld files") == "3 files")
    }

    @Test func polishPluralForms() {
        L10n.$localeOverride.withValue("pl") {
            for (count, text) in [(1, "1 plik"), (2, "2 pliki"), (5, "5 plików"), (22, "22 pliki")] {
                #expect(L10n.plural("test.files", count: count, one: "%lld file", other: "%lld files") == text)
            }
        }
    }

    @Test func formatFillsPositionalPlaceholdersInTheTranslationsOrder() {
        L10n.$localeOverride.withValue("de") {
            #expect(L10n.format("test.location", "%1$@ is in %2$@.", "Bericht", "Dokumente") == "In Dokumente liegt Bericht.")
        }
    }
}
