import MacCommanderCore
import SwiftUI

extension BrowserModel {
    /// Identifies a pane in `ForEach` and in the window's per-pane state.
    var paneID: ObjectIdentifier { ObjectIdentifier(self) }
}

/// One pane of a browser window: file list, search truncation notice and path bar of one `BrowserModel`,
/// plus that model's per-folder work (first load, its search, refresh on focus, search field text).
/// The window's share sheets come from the environment (`ShareSheets`).
struct PaneView: View {
    let model: BrowserModel
    let layout: PaneLayout
    /// This pane is `layout.active`.
    let isActive: Bool
    /// Marks the active pane; only in dual-pane mode.
    let showsActiveMarker: Bool
    /// Shows the pane's own truncation notice and path bar (dual-pane mode). In single-pane mode the window
    /// shows them below its split view, across the full width (as in v1).
    let showsFooter: Bool

    @Environment(ViewSettingsStore.self) private var settings
    @Environment(FileClipboard.self) private var clipboard
    @Environment(ShareManager.self) private var shareManager
    @Environment(ShareStore.self) private var shareStore
    @Environment(ShareSheets.self) private var shareSheets
    /// True while the window is key (or the app's active window); see the refresh on focus below.
    @Environment(\.appearsActive) private var appearsActive

    init(model: BrowserModel, layout: PaneLayout, isActive: Bool, showsActiveMarker: Bool, showsFooter: Bool) {
        self.model = model
        self.layout = layout
        self.isActive = isActive
        self.showsActiveMarker = showsActiveMarker
        self.showsFooter = showsFooter
    }

    var body: some View {
        VStack(spacing: 0) {
            FileListView(
                model: model, settings: settings, clipboard: clipboard,
                reconnect: { [shareStore, shareManager, shareSheets, model] disconnected in
                    Task {
                        await ShareActions.reconnect(
                            disconnected, store: shareStore, manager: shareManager, model: model,
                            sheets: shareSheets)
                    }
                },
                signIn: { [shareStore, shareSheets] disconnected in
                    guard let share = shareStore.shares.first(where: { $0.id == disconnected.id }) else { return }
                    Task { await ShareActions.showSignIn(share, sheets: shareSheets) }
                },
                // Activation follows keyboard focus, so menu commands (focused model) and responder-chain
                // commands (first-responder list) target the same pane.
                onActivate: { [layout, model] in
                    if layout.active !== model { layout.activate(model) }
                },
                onSwitchPane: layout.isDual ? { [layout] in layout.switchActive() } : nil,
                focusSerial: layout.focusSerial,
                isFocusTarget: layout.focusTarget == model.paneID,
                isActive: isActive)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsFooter {
                PaneFooter(model: model, isActive: isActive)
                    // A click on the path bar activates the pane and focuses its list; breadcrumbs still work.
                    .simultaneousGesture(TapGesture().onEnded { [layout, model] in
                        layout.activate(model)
                        layout.requestFocus(model)
                    })
            }
        }
        .overlay(alignment: .leading) {
            if showsActiveMarker, isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .allowsHitTesting(false)
            }
        }
        .task { await model.reload() }
        // Debounced: each keystroke restarts the wait. Clearing the field ends the search at once. Keyed by this
        // pane's own text, so switching panes neither cancels a pending search nor ends a shown one.
        .task(id: layout.searchText(for: model)) {
            let text = layout.searchText(for: model)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Not a tag view: the field is also cleared when one starts. With no search shown this still
                // drops a search request that is checking its folder.
                if case .tag? = model.search?.scope {} else { model.endSearch() }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.startSearch(text)
        }
        // A navigation (or Back) ends the search, and a tag view isn't a text search: clear the field.
        .onChange(of: model.search) { _, search in
            if search == nil || search?.scope != .folder(model.currentURL) { layout.setSearchText("", for: model) }
        }
        // Refresh on focus: a network folder isn't watched reliably, so it is listed again whenever its window
        // becomes active. Local folders rely on their watcher. The check uses the last load's cached info, and
        // a listing already in flight is kept (see `refreshOnFocus`).
        .onChange(of: appearsActive) { _, active in
            guard active, model.isOnNetworkVolume else { return }
            Task { await model.refreshOnFocus() }
        }
    }
}

/// A pane's search truncation notice and path bar. `isActive` nil: single-pane mode (no active styling).
struct PaneFooter: View {
    let model: BrowserModel
    var isActive: Bool? = nil

    var body: some View {
        VStack(spacing: 0) {
            if model.isSearching, model.searchTruncated {
                Divider()
                Text(String(localized: "More than 10,000 results; refine your search."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            Divider()
            PathBar(model: model, isActive: isActive)
        }
    }
}
