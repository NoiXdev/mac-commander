import Foundation
import MacCommanderCore
import SwiftUI

/// Confirms a copy/move/extract to the other pane (F5/F6, ⌘5/⌘6, Copy/Move to Other Pane). The field starts
/// with the other pane's folder; an edited path is used for this one operation only. OK checks the path off the
/// main actor (it may be on a network volume); Cancel stays usable meanwhile and abandons the check.
struct PaneTransferSheet: View {
    let request: PaneTransferRequest
    let onConfirm: (URL) -> Void
    let onCancel: () -> Void

    private let textState: State<String>
    private let errorState = State<String?>(initialValue: nil)
    /// The check of the typed path in flight; OK is disabled meanwhile.
    private let checkState = State<Task<Void, Never>?>(initialValue: nil)
    @FocusState private var fieldFocused: Bool
    private var text: Binding<String> { textState.projectedValue }
    private var error: String? {
        get { errorState.wrappedValue }
        nonmutating set { errorState.wrappedValue = newValue }
    }
    private var check: Task<Void, Never>? {
        get { checkState.wrappedValue }
        nonmutating set { checkState.wrappedValue = newValue }
    }

    init(request: PaneTransferRequest, onConfirm: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.request = request
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        textState = State(initialValue: request.destination.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title)
            // Focused when the sheet appears, which selects the whole path.
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .focused($fieldFocused)
                .onChange(of: text.wrappedValue) {
                    error = nil
                    check?.cancel()
                    check = nil
                }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                if check != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) {
                    check?.cancel()
                    check = nil
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "OK"), action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(check != nil)
            }
        }
        .padding(20)
        .onAppear { fieldFocused = true }
        // However the sheet goes away, a check still running must not confirm a transfer afterwards.
        .onDisappear {
            check?.cancel()
            check = nil
        }
    }

    /// Parses the path, then checks off the main actor that it is a folder; confirms or shows the error.
    /// Typing again or Cancel drops a check still running (a dead share may never answer).
    private func confirm() {
        // Return can fire again while a check runs (the disabled button doesn't stop the shortcut everywhere).
        guard check == nil else { return }
        guard
            let url = PaneTransfer.parseDestination(
                text.wrappedValue, home: FileManager.default.homeDirectoryForCurrentUser)
        else {
            error = String(localized: "Enter a full folder path, starting with / or ~.")
            return
        }
        error = nil
        check = Task {
            let path = url.path
            let isFolder = await PathQueries.run {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            guard !Task.isCancelled else { return }
            check = nil
            guard isFolder else {
                error = String(localized: "There’s no folder at this path.")
                return
            }
            onConfirm(url)
        }
    }
}
