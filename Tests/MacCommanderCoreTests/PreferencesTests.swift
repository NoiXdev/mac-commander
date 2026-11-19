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

    @Test func hiddenTagsRoundTripAndDecodeLeniently() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PreferencesStore(defaults: defaults)
        #expect(store.preferences.hiddenTags.isEmpty)
        store.preferences.hiddenTags = ["Work"]
        #expect(PreferencesStore(defaults: defaults).preferences.hiddenTags == ["Work"])
        // A wrong type falls back to empty; the other fields are kept.
        defaults.set(Data(#"{"newFileName": "a.txt", "hiddenTags": 3}"#.utf8), forKey: PreferencesStore.key)
        let again = PreferencesStore(defaults: defaults)
        #expect(again.preferences.hiddenTags.isEmpty)
        #expect(again.preferences.newFileName == "a.txt")
        // Non-string entries are dropped, the rest kept.
        defaults.set(Data(#"{"hiddenTags": ["Home", 4]}"#.utf8), forKey: PreferencesStore.key)
        #expect(PreferencesStore(defaults: defaults).preferences.hiddenTags == ["Home"])
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

    @Test func dualPaneDefaultsOffAndRoundTrips() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PreferencesStore(defaults: defaults)
        #expect(store.preferences.dualPaneEnabled == false)
        store.preferences.dualPaneEnabled = true
        #expect(PreferencesStore(defaults: defaults).preferences.dualPaneEnabled == true)
    }

    @Test func dualPaneDecodesLeniently() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data(#"{"newFileName": "a.md"}"#.utf8), forKey: PreferencesStore.key)
        let store = PreferencesStore(defaults: defaults)
        #expect(store.preferences.dualPaneEnabled == false)
        #expect(store.preferences.newFileName == "a.md")
        defaults.set(Data(#"{"dualPaneEnabled": "yes", "newFileName": "b.md"}"#.utf8), forKey: PreferencesStore.key)
        let again = PreferencesStore(defaults: defaults)
        #expect(again.preferences.dualPaneEnabled == false)
        #expect(again.preferences.newFileName == "b.md")
    }

    @Test func terminalAppRoundTripsAndDecodesLeniently() throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PreferencesStore(defaults: defaults)
        #expect(store.preferences.terminalApp == nil)
        store.preferences.terminalApp = .terminal
        #expect(PreferencesStore(defaults: defaults).preferences.terminalApp == .terminal)
        let decoded = try JSONDecoder().decode(
            Preferences.self, from: Data(#"{"terminalApp": "hyper", "newFileName": "a.md"}"#.utf8))
        #expect(decoded.terminalApp == nil)
        #expect(decoded.newFileName == "a.md")
    }

    @Test func globalShortcutDefaultsToNil() {
        #expect(Preferences().globalShortcut == nil)
    }

    @Test func globalShortcutRoundTrips() throws {
        var prefs = Preferences()
        prefs.globalShortcut = GlobalShortcut(keyCode: 46, modifiers: [.control, .option], key: "M")
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(Preferences.self, from: data).globalShortcut == prefs.globalShortcut)
    }

    @Test func unreadableGlobalShortcutIsNil() throws {
        let json = #"{"globalShortcut": "garbage", "newFileName": "x.txt"}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(prefs.globalShortcut == nil)
        #expect(prefs.newFileName == "x.txt")
    }
}
