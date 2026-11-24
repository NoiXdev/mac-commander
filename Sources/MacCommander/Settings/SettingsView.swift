import AppKit
import MacCommanderCore
import SwiftUI

/// The Settings window (⌘,): a sidebar of `SettingsSection`s on the left and the selected pane on the right, in
/// a window the user can resize and that keeps its size across launches. Every control writes its store at
/// once, so open browser windows change live, and the stores persist to `UserDefaults`.
struct SettingsView: View {
    /// The window's frame autosave name, so the size a resize is left at survives a relaunch.
    static let frameAutosaveName = "MacCommander.settings"

    /// The smallest the window's content can be made, below the toolbar. The SwiftUI frame carries it, and the
    /// scene's `.windowResizability(.contentMinSize)` turns it into the window's `contentMinSize` (which adds
    /// the toolbar itself, so it must not be written here). Width: the 180 pt sidebar plus the 460 pt minimum
    /// detail column, plus the grouped form's margins. Height: every pane fits or scrolls at 520 (Tags needs
    /// 360, Network about 300), measured with a probe app, 2026-11-24.
    static let minimumSize = CGSize(width: 680, height: 520)

    /// The sidebar's width, which is fixed: macSCP saw SwiftUI spin in a `_sizeThatFits` loop on macOS 26 when
    /// the sidebar was left to negotiate its width against the detail column.
    static let sidebarColumnWidth: CGFloat = 180

    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, id: \.self, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(Self.sidebarColumnWidth)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: GeneralSettings()
                case .view: AppearanceSettings()
                case .openWith: OpenWithSettings()
                case .terminal: TerminalSettings()
                case .shortcuts: ShortcutsSettings()
                case .sidebar: SidebarSettings()
                case .tags: TagsSettings()
                case .network: NetworkSettings()
                }
            }
            .navigationSplitViewColumnWidth(min: 460, ideal: 500)
            .navigationTitle((selection ?? .general).title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(SettingsWindowAccessor { window in
            // `.windowResizability(.contentMinSize)` on the scene honours the minimum but does NOT make a
            // SwiftUI Settings window draggable (measured in macSCP and here: the style mask stays without
            // `.resizable`). Inserting it is what does; only when missing, as this runs again and again.
            if !window.styleMask.contains(.resizable) {
                window.styleMask.insert(.resizable)
            }
            guard window.frameAutosaveName != Self.frameAutosaveName else { return }
            window.setFrameAutosaveName(Self.frameAutosaveName)
        })
    }
}
