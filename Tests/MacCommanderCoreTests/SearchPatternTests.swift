import Foundation
import Testing

@testable import MacCommanderCore

/// The string a comparison predicate compares against.
private func comparedValue(_ predicate: NSPredicate) -> String? {
    (predicate as? NSComparisonPredicate)?.rightExpression.constantValue as? String
}

struct SearchPatternTests {
    @Test func matchesCaseAndDiacriticInsensitive() {
        #expect(SearchPattern.matches("Résumé.pdf", text: "resume"))
        #expect(SearchPattern.matches("Résumé.pdf", text: "  RESUME "))
        #expect(!SearchPattern.matches("Notes", text: "x"))
        #expect(!SearchPattern.matches("Notes", text: "   "))
    }

    @Test func escapesWildcards() {
        #expect(SearchPattern.likeEscaped("a*b?c\\d") == "a\\*b\\?c\\\\d")
        #expect(SearchPattern.likeEscaped("it's") == "it\\'s")
        #expect(SearchPattern.likeEscaped("a\"b") == "a\"b")
    }

    @Test func predicateForFolderQuery() throws {
        let tmp = try TemporaryDirectory()
        let predicate = SpotlightSearch.predicate(for: SearchQuery(text: "a*\"b", scope: .folder(tmp.url)))
        #expect(predicate.predicateFormat.contains("kMDItemFSName"))
        #expect(predicate.predicateFormat.contains("LIKE[cd]"))
        #expect(predicate.evaluate(with: ["kMDItemFSName": "xa*\"by"]))
        #expect(!predicate.evaluate(with: ["kMDItemFSName": "xaZZby"]))
        #expect(predicate.evaluate(with: ["kMDItemFSName": "XA*\"BY"]))
        #expect(comparedValue(predicate) == "*a\\*\"b*")

        // NSMetadataQuery doesn't escape `'` in its MDQuery string, so the predicate must carry `\'`.
        let quote = SpotlightSearch.predicate(for: SearchQuery(text: " ECTS'99 ", scope: .folder(tmp.url)))
        #expect(comparedValue(quote) == "*ECTS\\'99*")
        #expect(quote.evaluate(with: ["kMDItemFSName": "Kurs ECTS'99"]))
        #expect(!quote.evaluate(with: ["kMDItemFSName": "OBJECTS"]))
    }

    @Test func predicateForTagWithQuoteAndWildcard() {
        let predicate = SpotlightSearch.predicate(for: SearchQuery(text: "", scope: .tag("Bob's *")))
        #expect(comparedValue(predicate) == "Bob\\'s \\*")
        #expect(predicate.evaluate(with: ["kMDItemUserTags": "bob's *"]))
        #expect(!predicate.evaluate(with: ["kMDItemUserTags": "Bob's anything"]))
    }

    @Test func predicateForTagQuery() {
        let predicate = SpotlightSearch.predicate(for: SearchQuery(text: "ignored", scope: .tag("Red")))
        #expect(predicate.predicateFormat.contains("kMDItemUserTags"))
        #expect(predicate.evaluate(with: ["kMDItemUserTags": "red"]))
        #expect(!predicate.evaluate(with: ["kMDItemUserTags": "Blue"]))
    }

    @Test func spotlightFilterDropsRootAndHidden() throws {
        let tmp = try TemporaryDirectory()
        let root = try FileItem.load(tmp.url)
        let shown = try FileItem.load(try tmp.file("report.txt"))
        let hidden = try FileItem.load(try tmp.file(".report"))
        let kept = SpotlightSearch.keep([root, shown, hidden], root: tmp.url, includeHidden: false)
        #expect(kept == [shown])
        let all = SpotlightSearch.keep([root, shown, hidden], root: tmp.url, includeHidden: true)
        #expect(all == [shown, hidden])
    }

    @Test func tagViewKeepsOnlyItemsStillTagged() throws {
        let tmp = try TemporaryDirectory()
        let tagged = try tmp.file("tagged.txt")
        let removed = try tmp.file("removed.txt")
        try TagStore.writeNow([FileTag(name: "Work", color: .none), FileTag(name: "Red", color: .red)], to: tagged)
        try TagStore.writeNow([FileTag(name: "Work", color: .none)], to: removed)
        let items = [try FileItem.load(tagged), try FileItem.load(removed)]
        // Case-insensitive, like Finder: the index still lists `removed.txt`, whose Red tag is gone.
        #expect(SpotlightSearch.keep(items, root: nil, tag: "red", includeHidden: false).map(\.name) == ["tagged.txt"])
        #expect(SpotlightSearch.keep(items, root: nil, tag: "WORK", includeHidden: false).count == 2)
        #expect(SpotlightSearch.keep(items, root: nil, includeHidden: false).count == 2)
    }
}
