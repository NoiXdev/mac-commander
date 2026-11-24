import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct OpenWithRulesTests {
    private func rule(_ name: String = "Typora") -> OpenWithRule {
        OpenWithRule(bundleIdentifier: "abnerworks.\(name)", appPath: "/Applications/\(name).app", appName: name)
    }

    @Test func normalizesTypedExtensions() {
        #expect(OpenWithRules.normalizedExtension(".MD ") == "md")
        #expect(OpenWithRules.normalizedExtension("md") == "md")
        #expect(OpenWithRules.normalizedExtension(" .tar") == "tar")
        #expect(OpenWithRules.normalizedExtension("..md") == nil)
        #expect(OpenWithRules.normalizedExtension("") == nil)
        #expect(OpenWithRules.normalizedExtension(".") == nil)
        #expect(OpenWithRules.normalizedExtension("a.b") == nil)
        #expect(OpenWithRules.normalizedExtension("a/b") == nil)
        #expect(OpenWithRules.normalizedExtension("  ") == nil)
    }

    @Test func matchesTheLastExtensionIgnoringCase() {
        var rules = OpenWithRules()
        rules.set(rule(), for: "md")
        rules.set(rule("Archiver"), for: "gz")
        #expect(rules.rule(for: URL(fileURLWithPath: "/x/Notes.Md")) == rule())
        #expect(rules.rule(for: URL(fileURLWithPath: "/x/a.tar.gz")) == rule("Archiver"))
        #expect(rules.rule(for: URL(fileURLWithPath: "/x/README")) == nil)
        #expect(rules.rule(for: URL(fileURLWithPath: "/x/.zshrc")) == nil)
    }

    @Test func setReplacesAnExistingRule() {
        var rules = OpenWithRules()
        rules.set(rule("One"), for: "md")
        rules.set(rule("Two"), for: ".MD")
        #expect(rules["md"] == rule("Two"))
        #expect(rules.extensions == ["md"])
    }

    @Test func setIgnoresAnInvalidExtension() {
        var rules = OpenWithRules()
        rules.set(rule(), for: ".")
        #expect(rules == OpenWithRules())
        #expect(rules.extensions.isEmpty)
    }

    @Test func removeDeletesTheRule() {
        var rules = OpenWithRules()
        rules.set(rule(), for: "md")
        rules.remove(".MD")
        #expect(rules.extensions.isEmpty)
    }

    @Test func extensionsAreSorted() {
        var rules = OpenWithRules()
        for ext in ["md", "json", "c"] { rules.set(rule(), for: ext) }
        #expect(rules.extensions == ["c", "json", "md"])
    }

    @Test func codableRoundTrip() throws {
        var rules = OpenWithRules()
        rules.set(rule(), for: "md")
        rules.set(OpenWithRule(bundleIdentifier: nil, appPath: "/A/B.app", appName: "B"), for: "json")
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode(OpenWithRules.self, from: data) == rules)
    }
}
