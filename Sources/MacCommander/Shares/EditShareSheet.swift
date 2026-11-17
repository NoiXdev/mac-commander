import MacCommanderCore
import SwiftUI

/// Edits a saved share: address, display name, user, automatic reconnect and guest access. Saving clears the
/// share's sign-in flag and, when something that affects mounting changed, re-classifies all shares (which
/// may reconnect this one).
struct EditShareSheet: View {
    let share: SavedShare
    @Environment(ShareStore.self) private var store
    @Environment(ShareManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    private let urlState: State<String>
    private let nameState: State<String>
    private let userState: State<String>
    private let reconnectState: State<Bool>
    private let guestState: State<Bool>
    private let duplicateState = State(initialValue: false)

    init(share: SavedShare) {
        self.share = share
        urlState = State(initialValue: share.url.url.absoluteString)
        nameState = State(initialValue: share.name)
        userState = State(initialValue: share.username ?? "")
        reconnectState = State(initialValue: share.autoReconnect)
        guestState = State(initialValue: share.lastAuth == .guest)
    }

    private var urlText: Binding<String> { urlState.projectedValue }
    private var name: Binding<String> { nameState.projectedValue }
    private var user: Binding<String> { userState.projectedValue }
    private var reconnect: Binding<Bool> { reconnectState.projectedValue }
    private var guest: Binding<Bool> { guestState.projectedValue }
    private var duplicate: Bool {
        get { duplicateState.wrappedValue }
        nonmutating set { duplicateState.wrappedValue = newValue }
    }

    private var parsedURL: ShareURL? { ShareURL(urlText.wrappedValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Edit “\(share.name)”")).font(.headline)
            Form {
                TextField(String(localized: "Address"), text: urlText)
                TextField(String(localized: "Name"), text: name)
                TextField(String(localized: "User"), text: user)
                    .disabled(guest.wrappedValue)
                Toggle(String(localized: "Reconnect automatically"), isOn: reconnect)
                    .toggleStyle(.checkbox)
                Toggle(String(localized: "Connect as Guest"), isOn: guest)
                    .toggleStyle(.checkbox)
            }
            if parsedURL == nil {
                Text(String(localized: "Enter a valid smb://, afp://, nfs://, https:// or http:// address."))
                    .font(.callout).foregroundStyle(.red)
            } else if duplicate {
                Text(String(localized: "Another saved share already uses this address."))
                    .font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: urlText.wrappedValue) { _, _ in duplicate = false }
    }

    /// Applies the fields the user changed to the share as it is now (re-read from the store: a sign-in or
    /// connect may have changed it while the sheet was open), so nothing newer is overwritten with the
    /// snapshot the sheet opened with.
    private func save() {
        guard let newURL = parsedURL else { return }
        guard let current = store.shares.first(where: { $0.id == share.id }) else {
            // Removed meanwhile.
            dismiss()
            return
        }
        if store.shares.contains(where: { $0.id != share.id && $0.url.matches(newURL) }) {
            duplicate = true
            return
        }
        var edited = current
        let urlChanged = newURL != share.url
        if urlChanged { edited.url = newURL }
        let trimmedName = name.wrappedValue.trimmingCharacters(in: .whitespaces)
        if trimmedName != share.name || urlChanged {
            edited.name = trimmedName.isEmpty ? edited.url.displayName : trimmedName
        }
        if reconnect.wrappedValue != share.autoReconnect { edited.autoReconnect = reconnect.wrappedValue }
        if guest.wrappedValue != (share.lastAuth == .guest) {
            edited.lastAuth = guest.wrappedValue ? .guest : .automatic
            if guest.wrappedValue { edited.username = nil }
        }
        if !guest.wrappedValue {
            let trimmedUser = user.wrappedValue.trimmingCharacters(in: .whitespaces)
            if trimmedUser != (share.username ?? "") { edited.username = trimmedUser.isEmpty ? nil : trimmedUser }
        }
        let needsRefresh =
            edited.url != current.url || edited.autoReconnect != current.autoReconnect
            || edited.lastAuth != current.lastAuth
        store.update(edited)
        // The old address's volume may still be mounted: it isn't offered as "Remember this share?".
        if edited.url != current.url { manager.addressChanged(from: current.url) }
        manager.clearSignInFlag(share.id)
        dismiss()
        if needsRefresh { manager.requestRefresh() }
    }
}
