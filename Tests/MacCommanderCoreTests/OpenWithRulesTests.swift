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

    // MARK: Resolving and grouping

    private let typoraID = "abnerworks.Typora"
    private let typora = URL(fileURLWithPath: "/Applications/Typora.app", isDirectory: true)
    private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)
    private let md = URL(fileURLWithPath: "/x/a.md")
    private let txt = URL(fileURLWithPath: "/x/b.txt")
    private let md2 = URL(fileURLWithPath: "/x/c.md")

    private func typoraRules(_ rule: OpenWithRule? = nil) -> OpenWithRules {
        var rules = OpenWithRules()
        rules.set(rule ?? self.rule(), for: "md")
        return rules
    }

    @Test func resolvesByBundleIdentifierFirst() {
        let located = URL(fileURLWithPath: "/Elsewhere/Typora.app", isDirectory: true)
        let locator = FakeLocator(bundles: [typoraID: located], existing: ["/Applications/Typora.app"])
        #expect(OpenWithRules.application(for: rule(), locator: locator) == located)
    }

    @Test func fallsBackToTheStoredPath() {
        let locator = FakeLocator(existing: ["/Applications/Typora.app"])
        let app = OpenWithRules.application(for: rule(), locator: locator)
        #expect(app?.path == "/Applications/Typora.app")
    }

    @Test func missingAppFallsBackToTheSystemDefault() {
        let locator = FakeLocator()
        #expect(OpenWithRules.application(for: rule(), locator: locator) == nil)
        #expect(typoraRules().groups(for: [md], locator: locator) == [OpenGroup(app: nil, urls: [md])])
    }

    @Test func groupsAMixedSelection() {
        let locator = FakeLocator(bundles: [typoraID: typora])
        #expect(typoraRules().groups(for: [md, txt, md2], locator: locator) == [
            OpenGroup(app: typora, urls: [md, md2]),
            OpenGroup(app: nil, urls: [txt]),
        ])
    }

    @Test func menuDefaultIsTheRuleAppForAUniformSelection() {
        let locator = FakeLocator(bundles: [typoraID: typora])
        #expect(typoraRules().menuDefault(for: [md, md2], locator: locator) == .app(typora))
    }

    @Test func menuDefaultIsNilForAMixedSelection() {
        let locator = FakeLocator(bundles: [typoraID: typora], systemDefaults: ["txt": textEdit])
        #expect(typoraRules().menuDefault(for: [md, txt], locator: locator) == MenuDefault.none)
    }

    @Test func menuDefaultKeepsTodaysChoiceWithoutRules() {
        let locator = FakeLocator(systemDefaults: ["txt": textEdit, "md": textEdit])
        #expect(OpenWithRules().menuDefault(for: [txt], locator: locator) == .system)
        #expect(typoraRules().menuDefault(for: [md, txt], locator: locator) == .system)
    }

    @Test func menuDefaultMatchesWhenRuleAndSystemAgree() {
        let locator = FakeLocator(bundles: [typoraID: typora], systemDefaults: ["txt": typora])
        #expect(typoraRules().menuDefault(for: [md, txt], locator: locator) == .app(typora))
    }

    @Test func rulesSkipPackages() {
        let package = URL(fileURLWithPath: "/x/Notes.rtfd", isDirectory: true)
        var rules = OpenWithRules()
        rules.set(rule(), for: "rtfd")
        let locator = FakeLocator(bundles: [typoraID: typora], directories: [package.path])
        #expect(rules.groups(for: [package], locator: locator) == [OpenGroup(app: nil, urls: [package])])
        #expect(rules.menuDefault(for: [package], locator: locator) == .system)
    }

    @Test func rulesSkipArchivesWhenOpening() {
        let archive = URL(fileURLWithPath: "/x/a.zip")
        var rules = OpenWithRules()
        rules.set(rule(), for: "zip")
        let locator = FakeLocator(bundles: [typoraID: typora])
        #expect(rules.groups(for: [archive], locator: locator) == [OpenGroup(app: nil, urls: [archive])])
        #expect(rules.menuDefault(for: [archive], locator: locator) == .app(typora))
    }

    @Test func applicationExistsRejectsAPlainFileOrFolder() throws {
        let dir = try TemporaryDirectory()
        let file = try dir.file("Fake.app")
        let folder = try dir.folder("Folder.app")
        let locator = WorkspaceApplicationLocator()
        #expect(locator.applicationExists(at: file) == false)
        #expect(locator.applicationExists(at: folder) == false)
        #expect(locator.applicationExists(at: dir.url.appendingPathComponent("Missing.app")) == false)
        let app = try #require(["/System/Applications/TextEdit.app", "/System/Applications/Calculator.app"]
            .first { FileManager.default.fileExists(atPath: $0) })
        #expect(locator.applicationExists(at: URL(fileURLWithPath: app, isDirectory: true)))
    }

    @Test func reportsOnlyRuleAppErrors() async {
        struct Failure: Error, Equatable { let app: URL? }
        let locator = FakeLocator(bundles: [typoraID: typora])
        let rules = typoraRules()

        let defaultFails = await PathQueries.open([txt], rules: rules, locator: locator, opening: { app, _ in
            app == nil ? Failure(app: nil) : nil
        })
        #expect(defaultFails == nil)

        let calls = OpenCalls()
        let everythingFails = await PathQueries.open([md, txt, md2], rules: rules, locator: locator, opening: { app, urls in
            calls.append(app, urls)
            return Failure(app: app)
        })
        #expect((everythingFails as? Failure) == Failure(app: typora))
        #expect(calls.sorted == [OpenGroup(app: typora, urls: [md, md2]), OpenGroup(app: nil, urls: [txt])])
    }
}

/// A locator with fixed answers: bundle id to app, paths that exist, extension to system default, paths
/// that are directories.
private struct FakeLocator: ApplicationLocating {
    var bundles: [String: URL] = [:]
    var existing: Set<String> = []
    var systemDefaults: [String: URL] = [:]
    var directories: Set<String> = []

    func applicationURL(bundleIdentifier: String) -> URL? { bundles[bundleIdentifier] }
    func applicationExists(at url: URL) -> Bool { existing.contains(url.path) }
    func systemDefaultApplication(for url: URL) -> URL? { systemDefaults[url.pathExtension] }
    func isDirectory(_ url: URL) -> Bool { directories.contains(url.path) }
}

/// The groups an `opening` closure was called with, from any thread.
private final class OpenCalls: @unchecked Sendable {
    // @unchecked: `calls` is only touched while holding `lock`.
    private let lock = NSLock()
    private var calls: [OpenGroup] = []

    func append(_ app: URL?, _ urls: [URL]) { lock.withLock { calls.append(OpenGroup(app: app, urls: urls)) } }

    /// Rule-app groups first, then the default group; the calls may run in any order.
    var sorted: [OpenGroup] { lock.withLock { calls.sorted { $0.app != nil && $1.app == nil } } }
}
