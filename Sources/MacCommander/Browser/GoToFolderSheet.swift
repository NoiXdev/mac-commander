import MacCommanderCore
import SwiftUI

struct GoToFolderSheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    private let textState = State(initialValue: "")
    private let failedState = State(initialValue: false)
    private var text: Binding<String> { textState.projectedValue }
    private var failed: Bool {
        get { failedState.wrappedValue }
        nonmutating set { failedState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Go to the folder:")
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .onChange(of: text.wrappedValue) { failed = false }
            if failed {
                Text("The folder can't be found.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func go() {
        let path = (text.wrappedValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !path.isEmpty else {
            failed = true
            return
        }
        let url: URL
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else if let location = ArchivePath.split(URL(fileURLWithPath: path)),
            !location.inner.isEmpty || ArchiveFormats.isArchive(location.archive)
        {
            // A pure archive, or a path inside any archive file (a few `stat`s, cheap). A missing inner
            // folder shows its deepest existing one.
            url = URL(fileURLWithPath: path, isDirectory: false)
        } else {
            failed = true
            return
        }
        dismiss()
        Task { await model.navigate(to: url) }
    }
}
