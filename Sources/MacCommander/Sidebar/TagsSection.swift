import MacCommanderCore
import SwiftUI

/// The sidebar's Tags section: one row per tag of the catalog (standard tags first, then custom ones),
/// except those removed from the sidebar (`Preferences.hiddenTags`, compared case-insensitively). A click
/// shows every file with that tag; the context menu renames, recolors or deletes a custom tag (`TagActions`).
struct TagsSection: View {
    let model: BrowserModel
    @Environment(PreferencesStore.self) private var preferences
    private let catalog = TagCatalog.shared

    var body: some View {
        Section(L10n.string("sidebar.section.tags", "Tags")) {
            ForEach(visibleTags, id: \.name) { tag in
                Label {
                    Text(tag.name).lineLimit(1)
                } icon: {
                    Self.dot(tag.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.showTag(tag.name) } }
                .contextMenu {
                    if !catalog.isStandard(tag) {
                        Button(L10n.string("tags.action.renameTag", "Rename Tag…")) { TagActions.rename(tag, preferences) }
                        Picker(L10n.string("tags.action.color", "Color"), selection: color(of: tag)) {
                            ForEach(TagActions.colorChoices, id: \.self) { color in
                                Text(TagActions.colorName(color)).tag(color)
                            }
                        }
                        Button(L10n.string("tags.action.deleteTag", "Delete Tag…")) { TagActions.delete(tag, preferences) }
                        Divider()
                    }
                    Button(L10n.string("tags.action.removeFromSidebar", "Remove Tag from Sidebar")) {
                        preferences.preferences.hiddenTags.insert(tag.name)
                    }
                    Button(L10n.string("tags.action.newTag", "New Tag…")) { TagActions.create(preferences) }
                }
            }
        }
    }

    private func color(of tag: FileTag) -> Binding<TagColor> {
        Binding(get: { tag.color }, set: { TagActions.recolor(tag, to: $0, preferences) })
    }

    private var visibleTags: [FileTag] {
        let hidden = Set(preferences.preferences.hiddenTags.map { $0.lowercased() })
        return catalog.tags.filter { !hidden.contains($0.name.lowercased()) }
    }

    /// A filled circle in the tag's color; an uncolored tag gets an outlined one.
    @ViewBuilder
    private static func dot(_ color: TagColor) -> some View {
        if color == .none {
            Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 10, height: 10)
        } else {
            Circle().fill(Color(nsColor: TagMenu.color(color))).frame(width: 10, height: 10)
        }
    }
}
