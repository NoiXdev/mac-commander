import MacCommanderCore
import SwiftUI

extension BrowserModel {
    /// Identifies a pane in `ForEach` and in the window's per-pane state.
    var paneID: ObjectIdentifier { ObjectIdentifier(self) }
}

/// One pane of a browser window: file list, search truncation notice and path bar of one `BrowserModel`,
/// plus that model's per-folder work (first load, folder changes, refresh on focus, search field text).
/// The window's share sheets come from the environment (`ShareSheets`).
struct PaneView: View {
    let model: BrowserModel
    let layout: PaneLayout
    /// This pane is `layout.active`.
    let isActive: Bool
    /// Marks the active pane; only in dual-pane mode.
    let showsActiveMarker: Bool
    /// Called with the pane's folder when it appears and whenever it changes.
    let onFolderChange: (URL) -> Void

    @Environment(ViewSettingsStore.self) private var settings
    @Environment(FileClipboard.self) private var clipboard
    @Environment(ShareManager.self) private var shareManager
    @Environment(ShareStore.self) private var shareStore
    @Environment(ShareSheets.self) private var shareSheets
    /// True while the window is key (or the app's active window); see the refresh on focus below.
    @Environment(\.appearsActive) private var appearsActive

    init(
        model: BrowserModel, layout: PaneLayout, isActive: Bool, showsActiveMarker: Bool,
        onFolderChange: @escaping (URL) -> Void
    ) {
        self.model = model
        self.layout = layout
        self.isActive = isActive
        self.showsActiveMarker = showsActiveMarker
        self.onFolderChange = onFolderChange
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
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isSearching, model.searchTruncated {
                Divider()
                Text(String(localized: "More than 10,000 results; refine your search."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            Divider()
            PathBar(model: model)
        }
        .task { await model.reload() }
        .onChange(of: model.currentURL, initial: true) { _, url in onFolderChange(url) }
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
