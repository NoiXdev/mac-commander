import Foundation
import Testing

@testable import MacCommanderCore

@MainActor
@Suite struct ViewSettingsStoreTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func settingsRoundTrip() {
        withDefaults { defaults in
            let store = ViewSettingsStore(defaults: defaults)
            var changed = store.settings
            changed.showHiddenFiles = true
            changed.columnLayout.columns[0].width = 333
            store.settings = changed

            let reloaded = ViewSettingsStore(defaults: defaults)
            #expect(reloaded.settings == changed)
            #expect(reloaded.settings.columnLayout.columns[0].width == 333)
        }
    }

    @Test func corruptDataFallsBackToDefaults() {
        withDefaults { defaults in
            let garbage = Data("garbage".utf8)
            defaults.set(garbage, forKey: "viewSettings.v1")
            let store = ViewSettingsStore(defaults: defaults)
            #expect(store.settings == ViewSettings())
            #expect(defaults.data(forKey: "viewSettings.v1") == garbage)
        }
    }

    @Test func layoutRepairsMissingColumns() throws {
        let json = Data(#"{"columns":[{"column":"name","width":200,"isVisible":true}]}"#.utf8)
        let layout = try JSONDecoder().decode(ColumnLayout.self, from: json)
        #expect(layout.columns.count == 8)
        #expect(layout.columns.first?.column == .name)
        #expect(layout.columns.first?.width == 200)
        #expect(Set(layout.columns.map(\.column)) == Set(FileColumn.allCases))
        // A layout stored before the Location column existed gets it appended.
        #expect(layout.columns.last == ColumnState(column: .location, width: 200, isVisible: true))
    }

    @Test func layoutDropsUnknownColumns() throws {
        let json = Data(
            #"{"columns":[{"column":"bogus","width":1,"isVisible":true},{"column":"size","width":50,"isVisible":false}]}"#
                .utf8)
        let layout = try JSONDecoder().decode(ColumnLayout.self, from: json)
        #expect(layout.columns.count == 8)
        #expect(layout.columns.first?.column == .size)
        #expect(layout.columns.first?.isVisible == false)
    }

    @Test func missingKeysKeepOtherSettings() {
        withDefaults { defaults in
            defaults.set(Data(#"{"showHiddenFiles":true}"#.utf8), forKey: "viewSettings.v1")
            let store = ViewSettingsStore(defaults: defaults)
            var expected = ViewSettings()
            expected.showHiddenFiles = true
            #expect(store.settings == expected)
        }
    }

    @Test func unknownSortColumnKeepsOtherSettings() {
        withDefaults { defaults in
            let json = #"{"showHiddenFiles":true,"sortOrder":{"column":"bogus","ascending":false,"foldersOnTop":true}}"#
            defaults.set(Data(json.utf8), forKey: "viewSettings.v1")
            let store = ViewSettingsStore(defaults: defaults)
            #expect(store.settings.showHiddenFiles)
            #expect(store.settings.sortOrder.column == .name)
            #expect(store.settings.sortOrder.ascending == false)
            #expect(store.settings.sortOrder.foldersOnTop)
        }
    }

    @Test func viewSettingsDecodeNewKeysLeniently() {
        withDefaults { defaults in
            defaults.set(Data(#"{"showHiddenFiles":true}"#.utf8), forKey: "viewSettings.v1")
            let old = ViewSettingsStore(defaults: defaults).settings
            #expect(old.showPreview == false)
            #expect(old.markdownShowsSource == false)
            #expect(old.showHiddenFiles)

            defaults.set(
                Data(#"{"showHiddenFiles":true,"showPreview":true,"markdownShowsSource":"bogus"}"#.utf8),
                forKey: "viewSettings.v1")
            let mixed = ViewSettingsStore(defaults: defaults).settings
            #expect(mixed.showPreview)
            #expect(mixed.markdownShowsSource == false)
            #expect(mixed.showHiddenFiles)
        }
    }
}
