import Foundation
import Testing

@testable import MacCommanderCore

/// Files by tag name, as Spotlight would report them (case-insensitively).
private struct FakeFinder: TaggedFileFinding {
    let files: [String: [URL]]

    func files(taggedWith name: String) async -> [URL] {
        files.first { $0.key.lowercased() == name.lowercased() }?.value ?? []
    }
}

@MainActor
struct TagEditorTests {
    private let tmp: TemporaryDirectory
    private let defaults = TemporaryDefaults()
    private let red = FileTag(name: "Red", color: .red)
    private let work = FileTag(name: "Work", color: .blue)
    private let home = FileTag(name: "Home", color: .green)

    init() throws {
        tmp = try TemporaryDirectory()
    }

    private func editor(_ files: [String: [URL]]) -> (TagEditor, TagCatalog, PreferencesStore) {
        let catalog = TagCatalog()
        catalog.start(standard: [red], known: [work, home])
        let preferences = PreferencesStore(defaults: defaults.make())
        return (TagEditor(catalog: catalog, preferences: preferences, finder: FakeFinder(files: files)), catalog, preferences)
    }

    private func tagged(_ name: String, _ tags: [FileTag]) throws -> URL {
        let url = try tmp.file(name)
        try TagStore.writeNow(tags, to: url)
        return url
    }

    private func strings(_ url: URL) -> [String] {
        TagStore.readNow(url).map { "\($0.name)/\($0.color)" }
    }

    @Test func renameChangesEveryFileAndTheCatalog() async throws {
        let a = try tagged("a.txt", [red, work])
        let b = try tagged("b.txt", [work])
        let (editor, catalog, _) = editor(["Work": [a, b]])

        try await editor.rename(work, to: "Job")

        #expect(strings(a) == ["Red/red", "Job/blue"])
        #expect(strings(b) == ["Job/blue"])
        #expect(catalog.tags.map(\.name) == ["Red", "Home", "Job"])
    }

    @Test func renameOntoAnotherTagMergesInItsColor() async throws {
        let a = try tagged("a.txt", [work, home])
        let (editor, catalog, _) = editor(["Work": [a]])

        try await editor.rename(work, to: "home")

        #expect(strings(a) == ["Home/green"])
        #expect(catalog.tags.map(\.name) == ["Red", "Home"])
    }

    @Test func recolorKeepsTheNameAndPosition() async throws {
        let a = try tagged("a.txt", [work, home])
        let (editor, catalog, _) = editor(["Work": [a]])

        try await editor.recolor(work, to: .purple)

        #expect(strings(a) == ["Work/purple", "Home/green"])
        #expect(catalog.tags.first { $0 == work }?.color == .purple)
    }

    @Test func deleteRemovesTheTagEverywhere() async throws {
        let a = try tagged("a.txt", [red, work])
        let (editor, catalog, preferences) = editor(["Work": [a]])
        preferences.preferences.hiddenTags = ["work", "Home"]

        try await editor.delete(work)

        #expect(strings(a) == ["Red/red"])
        #expect(!catalog.tags.contains(work))
        #expect(preferences.preferences.hiddenTags == ["Home"])
    }

    @Test func aHiddenTagStaysHiddenUnderItsNewName() async throws {
        let (editor, _, preferences) = editor([:])
        preferences.preferences.hiddenTags = ["work"]

        try await editor.rename(work, to: "Job")

        #expect(preferences.preferences.hiddenTags == ["Job"])
    }

    @Test func createdTagShowsAndAnExistingOneIsRecolored() async throws {
        let (editor, catalog, _) = editor([:])

        try await editor.create(FileTag(name: "Later", color: .orange))
        try await editor.create(FileTag(name: "home", color: .gray))

        #expect(catalog.tags.first { $0.name == "Later" }?.color == .orange)
        #expect(catalog.tags.first { $0 == home }?.color == .gray)
    }

    @Test func standardTagsAreLeftAlone() async throws {
        let a = try tagged("a.txt", [red])
        let (editor, catalog, _) = editor(["Red": [a]])

        #expect(!editor.isEditable(red))
        await #expect(throws: TagEditError.standardTag) { try await editor.delete(red) }
        await #expect(throws: TagEditError.standardTag) { try await editor.rename(red, to: "Urgent") }
        await #expect(throws: TagEditError.standardTag) { try await editor.rename(work, to: "red") }
        #expect(strings(a) == ["Red/red"])
        #expect(catalog.tags.contains(work))
    }

    /// A file that can't be written keeps the old tag, so the catalog keeps showing it; the others change.
    @Test func aFailedFileKeepsTheTagInTheCatalog() async throws {
        let a = try tagged("a.txt", [work])
        let missing = tmp.url.appendingPathComponent("gone.txt")
        let (editor, catalog, _) = editor(["Work": [missing, a]])

        await #expect(throws: TagEditError.filesNotChanged([missing])) { try await editor.delete(work) }

        #expect(strings(a) == [])
        #expect(catalog.tags.contains(work))
    }
}
