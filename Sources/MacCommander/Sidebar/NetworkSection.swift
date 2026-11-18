import MacCommanderCore
import SwiftUI

/// The sidebar's Network section: one row per saved share with its live status. A click goes to a connected
/// share, connects an available one (signing in if needed) and offers Retry for an unreachable one. With no
/// saved shares it holds a "Connect to Server…" row instead, so the section is never empty.
struct NetworkSection: View {
    let model: BrowserModel
    let sheets: ShareSheets
    @Environment(ShareStore.self) private var store
    @Environment(ShareManager.self) private var manager

    var body: some View {
        Section(String(localized: "Network")) {
            if store.shares.isEmpty {
                Label(String(localized: "Connect to Server…"), systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { sheets.showConnectToServer = true }
            } else {
                ForEach(store.shares) { share in
                    row(share, status: manager.status[share.id])
                }
            }
        }
    }

    private func row(_ share: SavedShare, status: ShareStatus?) -> some View {
        HStack(spacing: 4) {
            Label {
                Text(share.name).lineLimit(1)
            } icon: {
                Self.symbol(for: status)
            }
            Spacer(minLength: 0)
            if status == .available(needsSignIn: true) {
                Image(systemName: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(Self.tooltip(for: status))
        .onTapGesture { click(share, status: status) }
        .contextMenu {
            Button(String(localized: "Connect")) {
                Task { await ShareActions.connect(share, manager: manager, model: model, sheets: sheets) }
            }
            .disabled(Self.isConnected(status))
            Button(String(localized: "Disconnect")) {
                Task { await ShareActions.disconnect(share, manager: manager, sheets: sheets) }
            }
            .disabled(!(Self.isConnected(status) || (status == .unreachable && manager.hasMountPoint(share.id))))
            Button(String(localized: "Sign In…")) {
                Task { await ShareActions.showSignIn(share, sheets: sheets) }
            }
            .disabled(Self.isConnected(status))
            Divider()
            Button(String(localized: "Edit…")) { sheets.editing = share }
            Button(String(localized: "Remove…")) {
                Task { await ShareActions.confirmRemove(share, manager: manager, sheets: sheets) }
            }
        }
    }

    private func click(_ share: SavedShare, status: ShareStatus?) {
        Task {
            switch status {
            case .connected(let mountPoint)?:
                await model.navigate(to: share.url.folder(atMountPoint: mountPoint))
            case .unreachable?:
                await ShareActions.showUnreachable(share, manager: manager, model: model, sheets: sheets)
            case .available?, .checking?, nil:
                await ShareActions.connect(share, manager: manager, model: model, sheets: sheets)
            }
        }
    }

    private static func isConnected(_ status: ShareStatus?) -> Bool {
        if case .connected? = status { return true }
        return false
    }

    @ViewBuilder
    private static func symbol(for status: ShareStatus?) -> some View {
        switch status {
        case .connected?:
            Image(systemName: "circle.fill").foregroundStyle(.green)
        case .available?:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .unreachable?:
            Image(systemName: "network.slash").foregroundStyle(.red)
        case .checking?, nil:
            ProgressView().controlSize(.mini)
        }
    }

    private static func tooltip(for status: ShareStatus?) -> String {
        switch status {
        case .connected?: String(localized: "Connected")
        case .available(needsSignIn: true)?: String(localized: "Sign-in needed")
        case .available?: String(localized: "Not connected")
        case .unreachable?: String(localized: "Can’t be reached")
        case .checking?, nil: String(localized: "Checking…")
        }
    }
}
