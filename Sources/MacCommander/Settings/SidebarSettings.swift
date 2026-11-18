import MacCommanderCore
import SwiftUI

/// Sidebar settings: which sections the sidebar shows, and the tags removed from its Tags section.
struct SidebarSettings: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Form {
            Section(String(localized: "Show in Sidebar")) {
                ForEach(SidebarSection.allCases, id: \.self) { section in
                    Toggle(Self.title(for: section), isOn: shown(section))
                }
            }
            Section(String(localized: "Hidden Tags")) {
                if hiddenTags.isEmpty {
                    Text(String(localized: "No hidden tags"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hiddenTags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                            Spacer()
                            Button(String(localized: "Show")) { preferences.preferences.hiddenTags.remove(tag) }
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
        case .favorites: String(localized: "Favorites")
        case .iCloud: String(localized: "iCloud Drive")
        case .locations: String(localized: "Locations")
        case .network: String(localized: "Network")
        case .tags: String(localized: "Tags")
        }
    }
}
