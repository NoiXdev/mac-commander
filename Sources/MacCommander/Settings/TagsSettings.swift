import MacCommanderCore
import SwiftUI

/// Settings ▸ Tags: every tag of the catalog with its color, whether the sidebar shows it, and Rename and
/// Delete for custom tags (`TagActions`). Finder's standard color tags can only be shown or hidden.
struct TagsSettings: View {
    @Environment(PreferencesStore.self) private var preferences
    private let catalog = TagCatalog.shared

    var body: some View {
        Form {
            Section {
                ForEach(catalog.tags, id: \.name) { tag in
                    row(tag)
                }
            } header: {
                L10n.text("settings.section.tags", "Tags")
            } footer: {
                L10n.text("settings.tags.footer", "Renaming or deleting a tag changes every file in your home folder that Spotlight finds with it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.string("tags.action.newTag", "New Tag…")) { TagActions.create(preferences) }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }

    private func row(_ tag: FileTag) -> some View {
        let standard = catalog.isStandard(tag)
        return HStack {
            Image(nsImage: TagMenu.dotImage(tag.color))
            Text(tag.name).lineLimit(1)
            Spacer()
            if !standard {
                Picker(L10n.string("tags.action.color", "Color"), selection: color(of: tag)) {
                    ForEach(TagActions.colorChoices, id: \.self) { color in
                        Text(TagActions.colorName(color)).tag(color)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button(L10n.string("settings.tags.rename", "Rename…")) { TagActions.rename(tag, preferences) }
                Button(L10n.string("settings.tags.delete", "Delete…")) { TagActions.delete(tag, preferences) }
            }
            Toggle(L10n.string("settings.tags.showInSidebar", "Show in Sidebar"), isOn: shown(tag))
                .toggleStyle(.checkbox)
                .help(L10n.string("settings.tags.showInSidebar", "Show in Sidebar"))
                .labelsHidden()
        }
    }

    private func color(of tag: FileTag) -> Binding<TagColor> {
        Binding(get: { tag.color }, set: { TagActions.recolor(tag, to: $0, preferences) })
    }

    private func shown(_ tag: FileTag) -> Binding<Bool> {
        Binding(
            get: { !preferences.preferences.hiddenTags.contains { $0.lowercased() == tag.name.lowercased() } },
            set: { show in
                let others = preferences.preferences.hiddenTags.filter { $0.lowercased() != tag.name.lowercased() }
                preferences.preferences.hiddenTags = show ? others : others.union([tag.name])
            })
    }
}
