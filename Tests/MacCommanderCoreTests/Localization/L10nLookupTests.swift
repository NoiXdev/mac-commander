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

    @Test(.english) func englishTraitSetsTheOverride() {
        #expect(L10n.localeOverride == "en")
    }

    @Test func polishPluralForms() {
        L10n.$localeOverride.withValue("pl") {
            for (count, text) in [(1, "1 plik"), (2, "2 pliki"), (5, "5 plików"), (22, "22 pliki")] {
                #expect(L10n.plural("test.files", count: count, one: "%lld file", other: "%lld files") == text)
            }
        }
    }

    /// The tag counts of the rename and delete prompts. `TagActions` is in the app target, which tests can't import,
    /// so this looks the keys up with the same English the call sites pass.
    @Test(arguments: [
        (1, "Zmiana nazwy obejmie 1 plik.", "Usunięcie obejmie 1 plik."),
        (2, "Zmiana nazwy obejmie 2 pliki.", "Usunięcie obejmie 2 pliki."),
        (5, "Zmiana nazwy obejmie 5 plików.", "Usunięcie obejmie 5 plików."),
        (22, "Zmiana nazwy obejmie 22 pliki.", "Usunięcie obejmie 22 pliki."),
    ])
    func polishTagCountForms(count: Int, rename: String, delete: String) {
        L10n.$localeOverride.withValue("pl") {
            #expect(Self.tagRenameCount(count) == rename)
            #expect(Self.tagDeleteCount(count) == delete)
        }
    }

    @Test(.english) func englishTagCountForms() {
        #expect(Self.tagRenameCount(1) == "The tag is renamed on 1 file.")
        #expect(Self.tagRenameCount(3) == "The tag is renamed on 3 files.")
        #expect(Self.tagDeleteCount(1) == "It is removed from 1 file.")
        #expect(Self.tagDeleteCount(3) == "It is removed from 3 files.")
    }

    private static func tagRenameCount(_ count: Int) -> String {
        L10n.plural("tags.rename.files", count: count, one: "The tag is renamed on 1 file.", other: "The tag is renamed on %lld files.")
    }

    private static func tagDeleteCount(_ count: Int) -> String {
        L10n.plural("tags.delete.files", count: count, one: "It is removed from 1 file.", other: "It is removed from %lld files.")
    }

    @Test func formatFillsPositionalPlaceholdersInTheTranslationsOrder() {
        L10n.$localeOverride.withValue("de") {
            #expect(L10n.format("test.location", "%1$@ is in %2$@.", "Bericht", "Dokumente") == "In Dokumente liegt Bericht.")
        }
    }
}

/// `.english` on a suite reaches each of its tests.
@Suite(.english) struct EnglishSuiteTraitTests {
    @Test func suiteTraitSetsTheOverride() {
        #expect(L10n.localeOverride == "en")
    }

    @Test(arguments: [1, 2]) func suiteTraitReachesEveryTestCase(_ value: Int) {
        #expect(L10n.localeOverride == "en")
    }
}
