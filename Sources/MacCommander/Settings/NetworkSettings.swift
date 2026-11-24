import MacCommanderCore
import SwiftUI

/// Network settings: the saved shares with their live status, and Connect, Disconnect, Edit… and Remove… for
/// the selected one (enabled as in the sidebar's context menu). Connecting from here never navigates a browser
/// window (`model: nil`); sheets and alerts appear on the Settings window.
struct NetworkSettings: View {
    @Environment(ShareStore.self) private var store
    @Environment(ShareManager.self) private var manager
    private let sheetsState = State(initialValue: ShareSheets())
    private let selectionState = State<SavedShare.ID?>(initialValue: nil)

    private var sheets: ShareSheets { sheetsState.wrappedValue }
    private var selection: Binding<SavedShare.ID?> { selectionState.projectedValue }
    private var selected: SavedShare? {
        guard let id = selection.wrappedValue else { return nil }
        return store.shares.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List(selection: selection) {
                ForEach(store.shares) { share in
                    row(share, status: manager.status[share.id])
                        .tag(share.id)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 220, maxHeight: .infinity)
            .overlay {
                if store.shares.isEmpty {
                    L10n.text("settings.network.empty", "No saved shares")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                buttons
                Spacer()
                Button(L10n.string("shares.action.connectToServer", "Connect to Server…")) { sheets.showConnectToServer = true }
            }
        }
        .padding(20)
        .sheet(isPresented: Bindable(sheets).showConnectToServer) {
            ConnectToServerSheet(model: nil, sheets: sheets)
        }
        .sheet(item: Bindable(sheets).signIn) { share in
            SignInSheet(share: share, model: nil, sheets: sheets)
        }
        .sheet(item: Bindable(sheets).editing) { share in
            EditShareSheet(share: share)
        }
        .background(WindowReader(box: sheets.window))
    }

    private func row(_ share: SavedShare, status: ShareStatus?) -> some View {
        HStack(spacing: 8) {
            NetworkSection.symbol(for: status)
                .frame(width: 16)
                .help(NetworkSection.tooltip(for: status))
            VStack(alignment: .leading, spacing: 1) {
                Text(share.name).lineLimit(1)
                Text(share.url.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let share = selected
        let status = share.flatMap { manager.status[$0.id] }
        Button(L10n.string("shares.action.connect", "Connect")) {
            guard let share else { return }
            Task { await ShareActions.connect(share, manager: manager, model: nil, sheets: sheets) }
        }
        .disabled(share == nil || NetworkSection.isConnected(status))
        Button(L10n.string("shares.action.disconnect", "Disconnect")) {
            guard let share else { return }
            Task { await ShareActions.disconnect(share, manager: manager, sheets: sheets) }
        }
        .disabled(share.map { !NetworkSection.canDisconnect($0, status: status, manager: manager) } ?? true)
        Button(L10n.string("shares.action.edit", "Edit…")) { sheets.editing = share }
            .disabled(share == nil)
        Button(L10n.string("shares.action.remove", "Remove…")) {
            guard let share else { return }
            Task { await ShareActions.confirmRemove(share, manager: manager, sheets: sheets) }
        }
        .disabled(share == nil)
    }
}
