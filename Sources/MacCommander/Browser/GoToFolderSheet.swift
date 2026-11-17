import MacCommanderCore
import SwiftUI

struct GoToFolderSheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    private let textState = State(initialValue: "")
    private let failedState = State(initialValue: false)
    /// The check of the typed path in flight; Go is disabled meanwhile.
    private let checkState = State<Task<Void, Never>?>(initialValue: nil)
    private var text: Binding<String> { textState.projectedValue }
    private var failed: Bool {
        get { failedState.wrappedValue }
        nonmutating set { failedState.wrappedValue = newValue }
    }
    private var check: Task<Void, Never>? {
        get { checkState.wrappedValue }
        nonmutating set { checkState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Go to the folder:")
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onChange(of: text.wrappedValue) {
                    failed = false
                    check?.cancel()
                    check = nil
                }
            if failed {
                Text("The folder can't be found.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    check?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(check != nil)
            }
        }
        .padding(20)
    }

    /// Checks the path off the main actor (it may be on a network volume), then navigates or shows the error.
    /// Typing again or Cancel drops a check still running.
    private func go() {
        // Return can fire again while a check runs (the disabled button doesn't stop the shortcut everywhere).
        guard check == nil else { return }
        let path = (text.wrappedValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !path.isEmpty else {
            failed = true
            return
        }
        check = Task {
            let url = await Self.destination(path)
            guard !Task.isCancelled else { return }
            check = nil
            guard let url else {
                failed = true
                return
            }
            dismiss()
            await model.navigate(to: url)
        }
    }

    /// A folder, a pure archive, or a path inside any archive file (a missing inner folder shows its deepest
    /// existing one); nil for anything else.
    @concurrent
    private static func destination(_ path: String) async -> URL? {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        if await PathQueries.info(folder).isDirectory { return folder }
        let file = URL(fileURLWithPath: path, isDirectory: false)
        if let location = await PathQueries.archiveLocation(file),
            !location.inner.isEmpty || ArchiveFormats.isArchive(location.archive)
        {
            return file
        }
        return nil
    }
}
