import Foundation
import Testing

@testable import MacCommanderCore

@MainActor
struct PreferencesTests {
    private func suite() -> (UserDefaults, String) {
        let name = UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaultsRoundTrip() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PreferencesStore(defaults: defaults)
        #expect(store.preferences == Preferences())
        store.preferences.newFileName = "notes.md"
        let again = PreferencesStore(defaults: defaults)
        #expect(again.preferences.newFileName == "notes.md")
    }

    @Test func lenientDecoding() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let json = #"{"newFileName": 5, "hiddenSidebarSections": ["tags","bogus"]}"#
        defaults.set(Data(json.utf8), forKey: PreferencesStore.key)
        let store = PreferencesStore(defaults: defaults)
        #expect(store.preferences.newFileName == "untitled.txt")
        #expect(store.preferences.hiddenSidebarSections == [.tags])
    }

    @Test func invalidNewFileNameFallsBack() {
        for bad in ["", "  ", "a/b", "a:b", ".", ".."] {
            #expect(Preferences(newFileName: bad).effectiveNewFileName == "untitled.txt")
        }
        #expect(Preferences(newFileName: "notes.md").effectiveNewFileName == "notes.md")
    }

    @Test func createEmptyFileNamed() throws {
        let dir = try TemporaryDirectory()
        for (name, first, second) in [
            ("notes.md", "notes.md", "notes 2.md"),
            ("Makefile", "Makefile", "Makefile 2"),
            (".env", ".env", ".env 2"),
        ] {
            #expect(try ItemCreator.createEmptyFile(in: dir.url, named: name).lastPathComponent == first)
            #expect(try ItemCreator.createEmptyFile(in: dir.url, named: name).lastPathComponent == second)
        }
    }

    @Test func missingWindowFolderFallsBack() {
        let prefs = Preferences(newWindowFolderPath: "/nonexistent-\(UUID())")
        let url = prefs.newWindowFolder(exists: { FileManager.default.fileExists(atPath: $0.path) })
        #expect(url == FileManager.default.homeDirectoryForCurrentUser)
    }
}
