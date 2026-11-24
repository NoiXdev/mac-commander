import AppKit
import MacCommanderCore
import SwiftUI

struct BrowserCommands: Commands {
    let settings: ViewSettingsStore
    let preferences: PreferencesStore
    /// The app's one update check, shared with Settings and the launch check.
    let updates: UpdateCheckModel
    /// Opens new tabs (File ▸ New Tab).
    let router: OpenRequestRouter
    /// The focused window's active pane.
    @FocusedValue(\.browserModel) private var model
    @FocusedValue(\.paneLayout) private var layout
    @FocusedValue(\.goToFolderPresented) private var goToFolder
    @FocusedValue(\.shareSheets) private var shareSheets
    @FocusedValue(\.searchFocused) private var searchFocused

    var body: some Commands {
        // Directly under About MacCommander.
        CommandGroup(after: .appInfo) {
            Button(L10n.string("menu.app.checkForUpdates", "Check for Updates…")) {
                Task { await updates.check(manual: true, preferences: preferences) }
            }
            .disabled(updates.isChecking)
        }
        // The default New Window (⌘N) from WindowGroup stays; a new window starts at home.
        CommandGroup(after: .newItem) {
            // Directly under New Window: a tab in the frontmost browser window, at the same folder as ⌘N.
            Button(L10n.string("menu.file.newTab", "New Tab")) { router.openNewTab() }
                .keyboardShortcut("t")
            Button(L10n.string("menu.file.open", "Open")) { openSelection() }
                .keyboardShortcut("o")
                .disabled(model?.selection.isEmpty != false)
            Divider()
            // Not during a search: the new item would land in the folder the results hide.
            Button(L10n.string("menu.file.newFolder", "New Folder")) { run { await BrowserActions.newFolder($0) } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil || isInArchive || model?.isSearching == true)
            Button(L10n.string("menu.file.newEmptyFile", "New Empty File")) { run { await BrowserActions.newFile($0) } }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model == nil || isInArchive || model?.isSearching == true)
            Divider()
            Button(L10n.string("menu.file.duplicate", "Duplicate")) { send(#selector(FileOutlineView.duplicate(_:))) }
                .keyboardShortcut("d")
                .disabled(model?.selection.isEmpty != false || isInArchive)
            if preferences.preferences.dualPaneEnabled {
                // Into the other pane's folder, after a confirmation sheet (also F5/F6 in the list).
                Button(L10n.string("menu.file.copyToOtherPane", "Copy to Other Pane")) { layout?.requestTransfer(move: false) }
                    .keyboardShortcut("5")
                    .disabled(!canRequestTransfer(move: false))
                Button(L10n.string("menu.file.moveToOtherPane", "Move to Other Pane")) { layout?.requestTransfer(move: true) }
                    .keyboardShortcut("6")
                    .disabled(!canRequestTransfer(move: true))
            }
            Button(L10n.string("menu.file.moveToTrash", "Move to Trash")) { send(#selector(FileOutlineView.moveToTrash(_:))) }
                .keyboardShortcut(.delete)
                .disabled(model?.selection.isEmpty != false || isInArchive)
            Button(L10n.string("menu.file.getInfo", "Get Info")) { send(#selector(FileOutlineView.getInfo(_:))) }
                .keyboardShortcut("i")
                .disabled(model?.selection.isEmpty != false || isInArchive)
        }
        // Copy, Cut, Paste and Undo are the standard Edit items; a focused text field keeps them for its text.
        // No printing: this also frees ⇧⌘P (Page Setup…) for Show/Hide Preview.
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .pasteboard) {
            Button(L10n.string("menu.edit.moveItemHere", "Move Item Here")) { send(#selector(FileOutlineView.pasteAsMove(_:))) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(model == nil || isInArchive)
            Button(L10n.string("menu.edit.copyPath", "Copy Path")) { send(#selector(FileOutlineView.copyPath(_:))) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model?.selection.isEmpty != false || isInArchive)
            Button(L10n.string("menu.edit.copyFolderPath", "Copy Folder Path")) { if let model { FileActions.copyPaths([model.currentURL]) } }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(model == nil || isInArchive)
            Divider()
            // Placed before the standard text-editing group, so it takes ⌘F ahead of a text field's Find.
            Button(L10n.string("menu.edit.find", "Find…")) { searchFocused?.wrappedValue = true }
                .keyboardShortcut("f")
                .disabled(searchFocused == nil)
        }
        CommandMenu(L10n.string("menu.go.title", "Go")) {
            Button(L10n.string("menu.go.back", "Back")) { run { await $0.goBack() } }
                .keyboardShortcut("[")
                // Back also closes a shown search (Ruling P6-1), even without history.
                .disabled(model?.history.canGoBack != true && model?.isSearching != true)
            Button(L10n.string("menu.go.forward", "Forward")) { run { await $0.goForward() } }
                .keyboardShortcut("]")
                .disabled(model?.history.canGoForward != true)
            Button(L10n.string("menu.go.enclosingFolder", "Enclosing Folder")) { run { await $0.goUp() } }
                .keyboardShortcut(.upArrow)
                .disabled(model == nil)
            Divider()
            Button(L10n.string("menu.go.goToFolder", "Go to Folder…")) { goToFolder?.wrappedValue = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(goToFolder == nil)
            Button(L10n.string("menu.go.connectToServer", "Connect to Server…")) { shareSheets?.showConnectToServer = true }
                .keyboardShortcut("k")
                // Not while another sheet of the window is up (Connect to Server, sign-in, Edit, Go to Folder).
                .disabled(
                    shareSheets == nil || shareSheets?.isPresentingSheet == true || goToFolder?.wrappedValue == true
                        || layout?.pendingTransfer != nil)
            Button(L10n.string("menu.go.home", "Home")) { go(FileManager.default.homeDirectoryForCurrentUser) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(L10n.string("menu.go.desktop", "Desktop")) { go(home("Desktop")) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(L10n.string("menu.go.downloads", "Downloads")) { go(home("Downloads")) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button(L10n.string("menu.go.applications", "Applications")) { go(URL(fileURLWithPath: "/Applications", isDirectory: true)) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button(L10n.string("menu.view.refresh", "Refresh")) { run { await $0.reload() } }
                .keyboardShortcut("r")
                .disabled(model == nil)
            Divider()
            // The setting of the focused window's mode (single- and dual-pane windows each have their own).
            Button(
                settings.settings.showsPreview(dualPane: isDual)
                    ? L10n.string("menu.view.hidePreview", "Hide Preview") : L10n.string("menu.view.showPreview", "Show Preview")
            ) {
                settings.settings.togglePreview(dualPane: isDual)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Toggle(L10n.string("menu.view.showHiddenFiles", "Show Hidden Files"), isOn: Binding(
                get: { settings.settings.showHiddenFiles },
                set: { settings.settings.showHiddenFiles = $0 }))
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Toggle(L10n.string("menu.view.showCheckboxColumn", "Show Checkbox Column"), isOn: Binding(
                get: { settings.settings.showCheckboxColumn },
                set: { settings.settings.showCheckboxColumn = $0 }))
            if preferences.preferences.dualPaneEnabled {
                Divider()
                Toggle(L10n.string("menu.view.singlePane", "Single Pane"), isOn: Binding(
                    get: { layout?.isDual == false },
                    set: { if $0 { layout?.showSingle() } }))
                    .keyboardShortcut("1")
                    // Not while the transfer sheet is up: it targets the other pane.
                    .disabled(layout == nil || layout?.pendingTransfer != nil)
                Toggle(L10n.string("menu.view.dualPane", "Dual Pane"), isOn: Binding(
                    get: { layout?.isDual == true },
                    set: { if $0 { layout?.showDual() } }))
                    .keyboardShortcut("2")
                    .disabled(layout == nil)
                Button(L10n.string("menu.view.swapPanes", "Swap Panes")) { runLayout { await $0.swapFolders() } }
                    .disabled(layout?.isDual != true || layout?.pendingTransfer != nil)
                Button(L10n.string("menu.view.sameFolderInOtherPane", "Same Folder in Other Pane")) {
                    runLayout { await $0.showActiveFolderInOtherPane() }
                }
                .disabled(layout?.canShowActiveFolderInOtherPane != true || layout?.pendingTransfer != nil)
            }
        }
    }

    private var isDual: Bool { layout?.isDual ?? false }

    /// A copy/move to the other pane is possible (see `PaneLayout.transferRequest`), the window isn't
    /// showing a sheet (the transfer sheet itself, Go to Folder or a share sheet) and the active list isn't
    /// renaming an item inline.
    private func canRequestTransfer(move: Bool) -> Bool {
        guard let layout, layout.pendingTransfer == nil, !layout.isActiveRenaming, goToFolder?.wrappedValue != true,
            shareSheets?.isPresentingSheet != true
        else { return false }
        return layout.transferRequest(move: move) != nil
    }

    private func runLayout(_ action: @escaping @MainActor (PaneLayout) async -> Void) {
        guard let layout else { return }
        Task { await action(layout) }
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
