import Foundation
import Testing

@testable import MacCommanderCore

struct SearchPatternTests {
    @Test func matchesCaseAndDiacriticInsensitive() {
        #expect(SearchPattern.matches("Résumé.pdf", text: "resume"))
        #expect(SearchPattern.matches("Résumé.pdf", text: "  RESUME "))
        #expect(!SearchPattern.matches("Notes", text: "x"))
        #expect(!SearchPattern.matches("Notes", text: "   "))
    }

    @Test func escapesWildcards() {
        #expect(SearchPattern.likeEscaped("a*b?c\\d") == "a\\*b\\?c\\\\d")
    }

    @Test func predicateForFolderQuery() throws {
        let tmp = try TemporaryDirectory()
        let predicate = SpotlightSearch.predicate(for: SearchQuery(text: "a*\"b", scope: .folder(tmp.url)))
        #expect(predicate.predicateFormat.contains("kMDItemFSName"))
        #expect(predicate.predicateFormat.contains("LIKE[cd]"))
        #expect(predicate.evaluate(with: ["kMDItemFSName": "xa*\"by"]))
        #expect(!predicate.evaluate(with: ["kMDItemFSName": "xaZZby"]))
        #expect(predicate.evaluate(with: ["kMDItemFSName": "XA*\"BY"]))
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
}
