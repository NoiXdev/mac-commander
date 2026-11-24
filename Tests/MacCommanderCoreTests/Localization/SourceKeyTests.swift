import Testing

/// The sources and `en.lproj` agree: every `L10n` call's English text is the English table's value, and every
/// English key is used. Keys under `test.` are seeds for the lookup tests and need no call site.
@Suite struct SourceKeyTests {
    @Test func everyKeyUsedInSourcesHasItsEnglishText() throws {
        #expect(try LocalizationFiles.unreadableCallSites() == [], "pass the key and English text as plain literals")

        let strings = try LocalizationFiles.strings("en")
        let plurals = try LocalizationFiles.plurals("en")
        let callSites = try LocalizationFiles.callSites()
        #expect(!callSites.isEmpty)
        for site in callSites {
            switch site.english {
            case .text(let english):
                #expect(strings[site.key] == english, "\(site)")
            case .plural(let one, let other):
                #expect(plurals[site.key]?.forms["one"] == one, "\(site) one")
                #expect(plurals[site.key]?.forms["other"] == other, "\(site) other")
            }
        }
    }

    @Test func everyEnglishKeyIsUsed() throws {
        let used = Set(try LocalizationFiles.callSites().map(\.key))
        let keys = Set(try LocalizationFiles.strings("en").keys).union(try LocalizationFiles.plurals("en").keys)
        let unused = keys.subtracting(used).filter { !$0.hasPrefix("test.") }.sorted()
        #expect(unused == [], "en.lproj keys no source uses")
    }
}
