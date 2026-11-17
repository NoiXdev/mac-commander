import AppKit
import MacCommanderCore
import SwiftUI

struct BrowserCommands: Commands {
    let settings: ViewSettingsStore
    @FocusedValue(\.browserModel) private var model
    @FocusedValue(\.goToFolderPresented) private var goToFolder

    var body: some Commands {
        // The default New Window (⌘N) from WindowGroup stays; a new window starts at home.
        CommandGroup(after: .newItem) {
            Button("Open") { openSelection() }
                .keyboardShortcut("o")
                .disabled(model?.selection.isEmpty != false)
            Divider()
            Button("New Folder") { run { await BrowserActions.newFolder($0) } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil || isInArchive)
            Button("New Empty File") { run { await BrowserActions.newFile($0) } }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model == nil || isInArchive)
            Divider()
            Button("Duplicate") { send(#selector(FileOutlineView.duplicate(_:))) }
                .keyboardShortcut("d")
                .disabled(model?.selection.isEmpty != false || isInArchive)
            Button("Move to Trash") { send(#selector(FileOutlineView.moveToTrash(_:))) }
                .keyboardShortcut(.delete)
                .disabled(model?.selection.isEmpty != false || isInArchive)
            Button("Get Info") { send(#selector(FileOutlineView.getInfo(_:))) }
                .keyboardShortcut("i")
                .disabled(model?.selection.isEmpty != false || isInArchive)
        }
        // Copy, Cut, Paste and Undo are the standard Edit items; a focused text field keeps them for its text.
        // No printing: this also frees ⇧⌘P (Page Setup…) for Show/Hide Preview.
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .pasteboard) {
            Button("Move Item Here") { send(#selector(FileOutlineView.pasteAsMove(_:))) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(model == nil || isInArchive)
            Button("Copy Path") { send(#selector(FileOutlineView.copyPath(_:))) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model?.selection.isEmpty != false || isInArchive)
        }
        CommandMenu("Go") {
            Button("Back") { run { await $0.goBack() } }
                .keyboardShortcut("[")
                .disabled(model?.history.canGoBack != true)
            Button("Forward") { run { await $0.goForward() } }
                .keyboardShortcut("]")
                .disabled(model?.history.canGoForward != true)
            Button("Enclosing Folder") { run { await $0.goUp() } }
                .keyboardShortcut(.upArrow)
                .disabled(model == nil)
            Divider()
            Button("Go to Folder…") { goToFolder?.wrappedValue = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(goToFolder == nil)
            Button("Home") { go(FileManager.default.homeDirectoryForCurrentUser) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { go(home("Desktop")) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Downloads") { go(home("Downloads")) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Applications") { go(URL(fileURLWithPath: "/Applications", isDirectory: true)) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { run { await $0.reload() } }
                .keyboardShortcut("r")
                .disabled(model == nil)
            Divider()
            Button(
                settings.settings.showPreview
                    ? String(localized: "Hide Preview") : String(localized: "Show Preview")
            ) {
                settings.settings.showPreview.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Toggle("Show Hidden Files", isOn: Binding(
                get: { settings.settings.showHiddenFiles },
                set: { settings.settings.showHiddenFiles = $0 }))
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle("Show Checkbox Column", isOn: Binding(
                get: { settings.settings.showCheckboxColumn },
                set: { settings.settings.showCheckboxColumn = $0 }))
        }
    }

    /// Inside an archive the window is read-only: commands that write are disabled.
    private var isInArchive: Bool { model?.archiveLocation != nil }

    /// Opens the selection like ⌘↓, through the focused file list (the responder chain).
    private func openSelection() {
        send(#selector(FileOutlineView.openSelectedItems(_:)))
    }

    /// Sends `action` to the focused file list through the responder chain; beeps if nothing handles it.
    private func send(_ action: Selector) {
        if !NSApp.sendAction(action, to: nil, from: nil) {
            NSSound.beep()
        }
    }

    private func home(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name, isDirectory: true)
    }

    private func go(_ url: URL) {
        run { await $0.navigate(to: url) }
    }

    private func run(_ action: @escaping @MainActor (BrowserModel) async -> Void) {
        guard let model else { return }
        Task { await action(model) }
    }
}
