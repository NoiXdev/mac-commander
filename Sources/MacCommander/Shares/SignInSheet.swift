import MacCommanderCore
import SwiftUI

/// Signs in to a share: user name (a domain account as `DOMAIN\name` or `name@domain`), password, and
/// optionally saves the password in the Keychain. A rejected password (or a refused guest login) keeps the sheet
/// open with an inline error; any other outcome closes it and is handled like a click (navigation or an alert).
/// An attempt that ends after the sheet went away (Cancel, or replaced by a sheet for another share) is ignored,
/// so it never dismisses or acts for a sheet it doesn't belong to.
///
/// The password lives only in this sheet's state and is cleared after every attempt.
struct SignInSheet: View {
    let share: SavedShare
    let model: BrowserModel
    let sheets: ShareSheets
    @Environment(ShareManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    private let usernameState: State<String>
    private let passwordState = State(initialValue: "")
    private let rememberState = State(initialValue: false)
    /// The inline error after a rejected attempt.
    private let rejectionState = State<String?>(initialValue: nil)
    private let busyState = State(initialValue: false)
    /// Set by Cancel: an attempt still running is then ignored when it ends.
    private let cancelledState = State(initialValue: false)

    init(share: SavedShare, model: BrowserModel, sheets: ShareSheets) {
        self.share = share
        self.model = model
        self.sheets = sheets
        usernameState = State(initialValue: share.username ?? "")
    }

    private var username: Binding<String> { usernameState.projectedValue }
    private var password: Binding<String> { passwordState.projectedValue }
    private var remember: Binding<Bool> { rememberState.projectedValue }
    private var rejection: String? {
        get { rejectionState.wrappedValue }
        nonmutating set { rejectionState.wrappedValue = newValue }
    }
    private var busy: Bool {
        get { busyState.wrappedValue }
        nonmutating set { busyState.wrappedValue = newValue }
    }
    private var cancelled: Bool {
        get { cancelledState.wrappedValue }
        nonmutating set { cancelledState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Sign in to “\(share.name)”"))
                .font(.headline)
            Form {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(String(localized: "Username"), text: username)
                    Text(String(localized: "For a domain account use DOMAIN\\name or name@domain."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SecureField(String(localized: "Password"), text: password)
                Toggle(String(localized: "Remember in Keychain"), isOn: remember)
                    .toggleStyle(.checkbox)
            }
            .disabled(busy)
            if let rejection {
                Text(rejection)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Button(String(localized: "Connect as Guest")) { attempt(asGuest: true) }
                    .disabled(busy)
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) {
                    cancelled = true
                    password.wrappedValue = ""
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Connect")) { attempt(asGuest: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || trimmedUsername.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onDisappear { cancelled = true }
    }

    private var trimmedUsername: String {
        username.wrappedValue.trimmingCharacters(in: .whitespaces)
    }

    private func attempt(asGuest: Bool) {
        // Return can fire again while an attempt runs.
        guard !busy, asGuest || !trimmedUsername.isEmpty else { return }
        busy = true
        rejection = nil
        let user = trimmedUsername
        let secret = password.wrappedValue
        let keep = remember.wrappedValue
        Task {
            let outcome =
                asGuest
                ? await manager.connectAsGuest(share.id)
                : await manager.signIn(share.id, username: user, password: secret, remember: keep)
            password.wrappedValue = ""
            busy = false
            // Cancelled, or this sheet was replaced by one for another share.
            guard !cancelled, sheets.signIn?.id == share.id else { return }
            if outcome == .needsSignIn {
                rejection =
                    asGuest
                    ? String(localized: "This share doesn’t allow guest access.")
                    : String(localized: "The user name or password is incorrect.")
                return
            }
            dismiss()
            await ShareActions.handle(outcome, for: share, manager: manager, model: model, sheets: sheets)
        }
    }
}
