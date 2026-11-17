import MacCommanderCore
import SwiftUI

/// Signs in to a share: user name (a domain account as `DOMAIN\name` or `name@domain`), password, and
/// optionally saves the password in the Keychain. A rejected password keeps the sheet open with an inline
/// error; any other outcome closes it and is handled like a click (navigation or an alert).
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
    private let rejectedState = State(initialValue: false)
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
    private var rejected: Bool {
        get { rejectedState.wrappedValue }
        nonmutating set { rejectedState.wrappedValue = newValue }
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
            if rejected {
                Text(String(localized: "The user name or password is incorrect."))
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
    }

    private var trimmedUsername: String {
        username.wrappedValue.trimmingCharacters(in: .whitespaces)
    }

    private func attempt(asGuest: Bool) {
        // Return can fire again while an attempt runs.
        guard !busy, asGuest || !trimmedUsername.isEmpty else { return }
        busy = true
        rejected = false
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
            guard !cancelled else { return }
            if outcome == .needsSignIn {
                rejected = true
                return
            }
            dismiss()
            await ShareActions.handle(outcome, for: share, manager: manager, model: model, sheets: sheets)
        }
    }
}
