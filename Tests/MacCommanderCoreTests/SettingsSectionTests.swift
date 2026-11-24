import Testing

@testable import MacCommanderCore

@Suite struct SettingsSectionTests {
    @Test func sidebarOrderMatchesTheSpec() {
        #expect(SettingsSection.allCases == [.general, .view, .openWith, .terminal, .shortcuts, .sidebar, .tags, .network])
    }

    @Test(.english) func everySectionHasItsOwnSymbolAndTitle() {
        let all = SettingsSection.allCases
        #expect(Set(all.map(\.systemImage)).count == all.count)
        #expect(Set(all.map(\.title)).count == all.count)
        #expect(SettingsSection.view.title == "View")
        #expect(SettingsSection.shortcuts.systemImage == "keyboard")
        #expect(SettingsSection.openWith.title == "Open With")
        #expect(SettingsSection.openWith.systemImage == "doc.badge.gearshape")
    }
}
