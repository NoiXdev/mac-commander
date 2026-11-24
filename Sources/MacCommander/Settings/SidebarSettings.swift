import MacCommanderCore
import SwiftUI

/// Sidebar settings: which sections the sidebar shows, and the tags removed from its Tags section.
struct SidebarSettings: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Form {
            Section(L10n.string("settings.sidebar.show.header", "Show in Sidebar")) {
                ForEach(SidebarSection.allCases, id: \.self) { section in
                    Toggle(Self.title(for: section), isOn: shown(section))
                }
            }
            Section(L10n.string("settings.sidebar.hiddenTags.header", "Hidden Tags")) {
                if hiddenTags.isEmpty {
                    L10n.text("settings.sidebar.hiddenTags.empty", "No hidden tags")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hiddenTags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                            Spacer()
                            Button(L10n.string("settings.sidebar.hiddenTags.show", "Show")) { preferences.preferences.hiddenTags.remove(tag) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hiddenTags: [String] {
        preferences.preferences.hiddenTags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func shown(_ section: SidebarSection) -> Binding<Bool> {
        Binding(
            get: { !preferences.preferences.hiddenSidebarSections.contains(section) },
            set: { show in
                if show {
                    preferences.preferences.hiddenSidebarSections.remove(section)
                } else {
                    preferences.preferences.hiddenSidebarSections.insert(section)
                }
            })
    }

    static func title(for section: SidebarSection) -> String {
        switch section {
        case .favorites: L10n.string("sidebar.section.favorites", "Favorites")
        case .iCloud: L10n.string("sidebar.section.cloud", "Cloud")
        case .locations: L10n.string("sidebar.section.locations", "Locations")
        case .network: L10n.string("sidebar.section.network", "Network")
        case .tags: L10n.string("sidebar.section.tags", "Tags")
        }
    }
}
