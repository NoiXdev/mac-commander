import AppKit
import MacCommanderCore

/// The Convert ▸ submenu of the file list's context menu and the command behind it (spec 2.1, 2.3).
@MainActor
enum ConvertActions {
    /// The Convert ▸ item for `items`, or nil when there is nothing to offer: inside an archive, while a pane
    /// shows the Disconnected placeholder, with a folder in the selection, or when the files share no target.
    /// The menu is built from the cached ffmpeg status; the status is refreshed for the next menu.
    static func menuItem(for items: [FileItem], model: BrowserModel, window: NSWindow?) -> NSMenuItem? {
        guard !items.isEmpty, model.archiveLocation == nil, !items.contains(where: \.isDirectory) else { return nil }
        if case .shareDisconnected? = model.loadError { return nil }
        Task { _ = await FFmpegLocator.shared.status() }

        let urls = items.map(\.url)
        // One stat per `.bin` (its `.cue` beside it): local metadata, cheap enough while the menu is built.
        let convertMenu = ConvertCatalog.menu(
            for: urls, ffmpeg: FFmpegLocator.shared.cachedStatus ?? .missing,
            cueExists: { FileManager.default.fileExists(atPath: $0.path) })
        guard !convertMenu.targets.isEmpty || convertMenu.ffmpegHint != nil else { return nil }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for target in convertMenu.targets {
            submenu.addItem(ActionMenuItem(target.label) {
                Task { @MainActor in await run(urls, to: target, model: model, window: window) }
            })
        }
        if let hint = convertMenu.ffmpegHint {
            if !convertMenu.targets.isEmpty { submenu.addItem(.separator()) }
            let item = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: String(localized: "Convert"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Converts `urls` to `target` in one operation, selects the outputs and reports failures in one alert.
    /// For ISO, a CUE sheet with audio tracks is confirmed first (Cancel aborts the command).
    static func run(_ urls: [URL], to target: ConvertTarget, model: BrowserModel, window: NSWindow?) async {
        if target == .iso, !(await confirmAudioTracks(urls, window: window)) { return }
        // Only ffmpeg targets wait for the (cached) check.
        var ffmpeg: URL?
        if target.needsFFmpeg, case .available(let url) = await FFmpegLocator.shared.status() { ffmpeg = url }
        let sheetWindow = WindowReference(window)
        // Called from the operation's thread; the prompt runs on the main actor.
        let result = await model.operations.convert(urls, to: target, ffmpeg: ffmpeg) { archive, incorrect in
            await askPassword(for: archive, incorrect: incorrect, in: sheetWindow)
        }
        if !result.outputs.isEmpty { await model.selectAfterOperation(result.outputs) }

        var messages = result.failures.map { failure in
            String(localized: "“\(failure.source.lastPathComponent)” couldn’t be converted: \(failure.message)")
        }
        if result.zeroFilledSectors > 0 {
            messages.append(
                result.zeroFilledSectors == 1
                    ? String(localized: "1 unreadable sector was written as zeros.")
                    : String(localized: "\(result.zeroFilledSectors) unreadable sectors were written as zeros."))
        }
        FileActions.showAlert(messages, window: window)
    }

    private static func askPassword(for archive: URL, incorrect: Bool, in reference: WindowReference) async -> String? {
        await ArchivePasswordSheet.ask(for: archive, incorrect: incorrect, window: reference.window)
    }

    /// Asks, for each CUE sheet among the sources that has audio tracks, whether to convert without them.
    /// The sheets are read off the main thread; one that can't be read or parsed is left to the conversion,
    /// which reports it.
    private static func confirmAudioTracks(_ urls: [URL], window: NSWindow?) async -> Bool {
        let audioTracks: [(name: String, count: Int)] = await PathQueries.run {
            let sources = ConvertCatalog.sources(
                for: urls, cueExists: { FileManager.default.fileExists(atPath: $0.path) })
            return sources.compactMap { source in
                guard source.pathExtension.lowercased() == "cue", let data = try? Data(contentsOf: source),
                    let sheet = try? CueSheet.parse(String(decoding: data, as: UTF8.self)), sheet.audioTrackCount > 0
                else { return nil }
                return (source.lastPathComponent, sheet.audioTrackCount)
            }
        }
        for (name, count) in audioTracks {
            let alert = NSAlert()
            alert.alertStyle = .informational
            if count == 1 {
                alert.messageText = String(localized: "“\(name)” has 1 audio track.")
                alert.informativeText = String(
                    localized: "An ISO can only hold the data track; the audio track will be left out.")
            } else {
                alert.messageText = String(localized: "“\(name)” has \(count) audio tracks.")
                alert.informativeText = String(
                    localized: "An ISO can only hold the data track; the audio tracks will be left out.")
            }
            alert.addButton(withTitle: String(localized: "Convert"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let response: NSApplication.ModalResponse
            if let window, window.isVisible, window.attachedSheet == nil {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn else { return false }
        }
        return true
    }
}

/// Carries the window into the conversion's password prompt, which is asked from off the main actor.
@MainActor
private final class WindowReference {
    weak var window: NSWindow?
    init(_ window: NSWindow?) { self.window = window }
}
