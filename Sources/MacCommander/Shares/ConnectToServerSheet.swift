import AppKit
import MacCommanderCore
import SwiftUI

/// Go ▸ Connect to Server… (⌘K): a share URL, checked with `ShareURL` as it is typed, and the recent server
/// URLs of the saved shares. Connect saves the share (or finds the saved one), closes the sheet and connects;
/// the outcome is handled like a sidebar click (navigation, sign-in sheet or an alert). A user name typed in the
/// address (`smb://bob@nas/Share`) is kept as the share's user; a password typed there is ignored.
struct ConnectToServerSheet: View {
    static let recentLimit = 10
    /// The address field's placeholder: an example URL, so it isn't translated. A `String`, so SwiftUI shows it
    /// verbatim instead of looking it up.
    static let addressExample = "smb://server/share"

    /// nil in the Settings window: a connected share isn't navigated to.
    let model: BrowserModel?
    let sheets: ShareSheets
    @Environment(ShareStore.self) private var store
    @Environment(ShareManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    private let textState = State(initialValue: "")
    private var text: Binding<String> { textState.projectedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            L10n.text("shares.connect.address", "Server Address:")
            TextField(Self.addressExample, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            if !recent.isEmpty {
                L10n.text("shares.connect.recent", "Recent")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                List(recent, id: \.self) { address in
                    Text(address)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { text.wrappedValue = address }
                }
                .listStyle(.bordered)
                .frame(width: 380, height: 140)
            }
            HStack {
                Spacer()
                Button(L10n.string("shares.action.cancel", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("shares.action.connect", "Connect"), action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(shareURL == nil)
            }
        }
        .padding(20)
    }

    private var shareURL: ShareURL? {
        ShareURL(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The saved shares' URLs, most recently added first, without duplicates.
    private var recent: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for share in store.shares.reversed() {
            let address = share.url.url.absoluteString
            guard seen.insert(address).inserted else { continue }
            result.append(address)
            if result.count == Self.recentLimit { break }
        }
        return result
    }

    private func connect() {
        // Return can fire although the button is disabled.
        guard let url = shareURL else { return NSSound.beep() }
        let username = ShareURL.username(in: text.wrappedValue)
        dismiss()
        let manager = manager
        let model = model
        let sheets = sheets
        Task {
            let (share, outcome) = await manager.addAndConnect(url, username: username)
            await ShareActions.handle(outcome, for: share, manager: manager, model: model, sheets: sheets)
        }
    }
}
