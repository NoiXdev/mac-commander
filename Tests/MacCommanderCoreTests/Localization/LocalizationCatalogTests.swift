import Testing

/// The four languages' tables agree with English: same keys, no empty values, the same placeholders, and the
/// plural categories each language needs.
@Suite struct LocalizationCatalogTests {
    static let translations = LocalizationFiles.languages.filter { $0 != "en" }

    @Test(arguments: translations) func everyLanguageHasTheSameKeys(language: String) throws {
        let english = Set(try LocalizationFiles.strings("en").keys)
        let strings = Set(try LocalizationFiles.strings(language).keys)
        #expect(english.subtracting(strings).sorted() == [], "missing from \(language) Localizable.strings")
        #expect(strings.subtracting(english).sorted() == [], "not in en Localizable.strings")

        let englishPlurals = Set(try LocalizationFiles.plurals("en").keys)
        let plurals = Set(try LocalizationFiles.plurals(language).keys)
        #expect(englishPlurals.subtracting(plurals).sorted() == [], "missing from \(language) Localizable.stringsdict")
        #expect(plurals.subtracting(englishPlurals).sorted() == [], "not in en Localizable.stringsdict")
    }

    @Test(arguments: LocalizationFiles.languages) func noValueIsEmpty(language: String) throws {
        for (key, value) in try LocalizationFiles.strings(language) {
            #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) \(key)")
        }
        for (key, entry) in try LocalizationFiles.plurals(language) {
            for (category, form) in entry.forms {
                #expect(!form.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) \(key) \(category)")
            }
        }
    }

    @Test(arguments: translations) func placeholdersMatchEnglish(language: String) throws {
        let english = try LocalizationFiles.strings("en")
        for (key, value) in try LocalizationFiles.strings(language) {
            guard let englishValue = english[key] else { continue }
            #expect(
                LocalizationFiles.placeholders(in: value) == LocalizationFiles.placeholders(in: englishValue),
                "\(language) \(key): \(value)")
        }

        // A form may spell out its number ("1 file"), so compare the placeholders all forms use together.
        let englishPlurals = try LocalizationFiles.plurals("en")
        for (key, entry) in try LocalizationFiles.plurals(language) {
            guard let englishEntry = englishPlurals[key] else { continue }
            #expect(
                LocalizationFiles.placeholders(in: entry.format)
                    == LocalizationFiles.placeholders(in: englishEntry.format),
                "\(language) \(key) format")
            #expect(placeholdersOfAllForms(entry) == placeholdersOfAllForms(englishEntry), "\(language) \(key)")
        }
    }

    @Test(arguments: LocalizationFiles.languages) func pluralsHaveEachLanguagesCategories(language: String) throws {
        // CLDR: Polish has one (1), few (2–4, 22–24 …), many (0, 5–21 …) and other (fractions).
        let categories: Set = language == "pl" ? ["one", "few", "many", "other"] : ["one", "other"]
        for (key, entry) in try LocalizationFiles.plurals(language) {
            #expect(Set(entry.forms.keys) == categories, "\(language) \(key)")
            #expect(entry.format == "%#@\(entry.variable)@", "\(language) \(key): the format is only the variable")
        }
    }

    private func placeholdersOfAllForms(_ entry: PluralEntry) -> Set<String> {
        Set(entry.forms.values.flatMap(LocalizationFiles.placeholders(in:)))
    }
}
