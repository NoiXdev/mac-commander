import AppKit
import MacCommanderCore
import Observation
import UniformTypeIdentifiers

/// What the preview panel shows below its header.
enum PreviewContent: Equatable {
    /// A centered placeholder text ("No Selection", "2 items", a folder's name inside an archive).
    case empty(String)
    /// A real file or folder shown by `QLPreviewView` (for an archive entry: its extracted copy).
    case quickLook(URL)
    /// A file rendered by a `PreviewRenderer`; `file` is the real file that was rendered.
    case rendered(RenderedPreview, file: URL)
    /// The raw text of `file` ("Show Source" for a file too large to render).
    case source(String, file: URL)
    /// A message with buttons below it.
    case message(String, actions: [PreviewAction])
}

/// A button under a `.message`.
enum PreviewAction: Equatable {
    /// Loads `MarkdownPreviewRenderer.sourceText(of:)` for the file and shows it as `.source`.
    case showSource(URL)

    var title: String {
        switch self {
        case .showSource: String(localized: "Show Source")
        }
    }
}

/// The line above the content: icon, name, kind and size, modification date.
struct PreviewHeader {
    var icon: NSImage
    var name: String
    /// "<Kind> — <size>"; the size only for files.
    var detail: String
    var modified: String?
}

/// Resolves what the preview panel shows for the window's selection. One per window.
///
/// Watches `model.selection`, `model.currentURL` and `settings.showPreview`. A selection or folder change
/// resolves after 150 ms without further changes (holding ↓ through a folder resolves only once, at the
/// end); showing the panel resolves at once. While the panel is hidden nothing is resolved, read or
/// extracted.
///
/// Each resolution bumps `generation`; its work runs in one `Task` that is cancelled when a newer
/// resolution starts or the inputs change, and its results are applied only while the generation and
/// the selection are still the ones it started with.
///
/// The selected `FileItem` is taken from `model.items` (the listed folder's rows). A row of an inline
/// expanded subfolder isn't in `items`: a real file is loaded with `FileItem.load` off the main thread, an
/// archive entry is looked up in its parent's listing (`model.children(of:)`, a cached catalog lookup).
@MainActor @Observable
final class PreviewController {
    private(set) var content: PreviewContent = .empty("")
    private(set) var header: PreviewHeader?

    @ObservationIgnored private let model: BrowserModel
    @ObservationIgnored private let settings: ViewSettingsStore
    @ObservationIgnored private let registry: MacCommanderCore.PreviewRegistry
    @ObservationIgnored private(set) var generation = 0
    /// The debounce sleep before the next resolution.
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// The running resolution (item lookup, extraction, rendering) or "Show Source" load.
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The inputs last seen, to ignore unrelated settings changes.
    @ObservationIgnored private var observedSelection: Set<URL>
    @ObservationIgnored private var observedURL: URL
    @ObservationIgnored private var observedShown: Bool

    private static let debounce = Duration.milliseconds(150)
    nonisolated private static let headerIconSize = NSSize(width: 48, height: 48)

    init(model: BrowserModel, settings: ViewSettingsStore, registry: MacCommanderCore.PreviewRegistry = .standard) {
        self.model = model
        self.settings = settings
        self.registry = registry
        observedSelection = model.selection
        observedURL = model.currentURL
        observedShown = settings.settings.showPreview
        observe()
        if observedShown { resolve() }
    }

    // MARK: - Observation

    private func observe() {
        withObservationTracking {
            _ = model.selection
            _ = model.currentURL
            _ = settings.settings.showPreview
        } onChange: { [weak self] in
            // Called before the change is applied; read the new values on the next main-actor turn.
            Task { @MainActor in self?.inputsDidChange() }
        }
    }

    private func inputsDidChange() {
        observe()
        let selection = model.selection
        let url = model.currentURL
        let shown = settings.settings.showPreview
        let wasShown = observedShown
        let changed = selection != observedSelection || url != observedURL
        observedSelection = selection
        observedURL = url
        observedShown = shown
        if !shown {
            if wasShown { reset() }
            return
        }
        if !wasShown {
            resolve()
        } else if changed {
            // Superseded: stop extracting or rendering for the old selection now, resolve once it settles.
            cancelWork()
            pending = Task { [weak self] in
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                self?.resolve()
            }
        }
    }

    private func cancelWork() {
        pending?.cancel()
        pending = nil
        work?.cancel()
        work = nil
    }

    /// The panel was hidden: drop everything (the Quick Look view goes away with the pane).
    private func reset() {
        cancelWork()
        generation += 1
        content = .empty("")
        header = nil
    }

    // MARK: - Resolution

    private func resolve() {
        cancelWork()
        generation += 1
        let selection = model.selection
        guard selection.count == 1, let url = selection.first else {
            header = nil
            content = .empty(
                selection.isEmpty
                    ? String(localized: "No Selection")
                    : String(localized: "\(selection.count) items"))
            return
        }
        let generation = generation
        work = Task { [weak self] in
            await self?.resolve(url, generation: generation, selection: selection)
        }
    }

    /// True while a result for `generation` / `selection` may still be shown.
    private func isCurrent(_ generation: Int, _ selection: Set<URL>) -> Bool {
        !Task.isCancelled && generation == self.generation && model.selection == selection
    }

    private func resolve(_ url: URL, generation: Int, selection: Set<URL>) async {
        let archive = model.archiveLocation?.archive
        let inner = archive.flatMap { ArchivePath.inner(of: url, in: $0) }
        guard let item = await item(for: url, inArchive: inner != nil), isCurrent(generation, selection) else {
            if isCurrent(generation, selection) { showUnpreviewable(url.lastPathComponent) }
            return
        }
        if let archive, let inner {
            await resolveArchiveEntry(item, inner: inner, of: archive, generation: generation, selection: selection)
            return
        }
        // Shown at once with the type icon; the file's own icon follows.
        header = Self.header(for: item, icon: Self.typeIcon(for: item))
        await resolveFile(url, name: item.name, isFolder: item.isDirectory || item.isPackage,
                          generation: generation, selection: selection)
        let icon = await Self.fileIcon(for: url)
        if isCurrent(generation, selection) { header?.icon = icon }
    }

    /// Folders and symlinks show their name; files are extracted (through the preview cache) and then
    /// previewed like real files. A password error never prompts: Space does that.
    private func resolveArchiveEntry(
        _ item: FileItem, inner: String, of archive: URL, generation: Int, selection: Set<URL>
    ) async {
        header = Self.header(for: item, icon: Self.typeIcon(for: item))
        // A symlink would be followed out of the cache; the cache refuses it anyway.
        if item.isDirectory || item.isPackage || item.isSymlink {
            content = .empty(item.name)
            return
        }
        let extracted: URL
        do {
            guard let file = try await ArchivePreviewCache.shared.files([inner], of: archive).first else {
                if isCurrent(generation, selection) { showUnpreviewable(item.name) }
                return
            }
            extracted = file
        } catch {
            guard isCurrent(generation, selection) else { return }
            switch error {
            case .passwordRequired, .incorrectPassword:
                content = .empty(String(localized: "Encrypted. Press Space to enter the password."))
            case .cancelled:
                break
            default:
                showUnpreviewable(item.name)
            }
            return
        }
        guard isCurrent(generation, selection) else { return }
        await resolveFile(extracted, name: item.name, isFolder: false, generation: generation, selection: selection)
    }

    /// Folders and packages, and files no renderer takes, go to Quick Look; the rest is rendered.
    private func resolveFile(_ url: URL, name: String, isFolder: Bool, generation: Int, selection: Set<URL>) async {
        guard !isFolder, let renderer = registry.renderer(for: url) else {
            content = .quickLook(url)
            return
        }
        do {
            let rendered = try await renderer.render(url)
            guard isCurrent(generation, selection) else { return }
            content = .rendered(rendered, file: url)
        } catch {
            guard isCurrent(generation, selection) else { return }
            switch error {
            case .tooLarge(let bytes):
                let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                content = .message(
                    String(localized: "“\(name)” is too large to render (\(size))."),
                    actions: [.showSource(url)])
            case .unreadable:
                showUnpreviewable(name)
            }
        }
    }

    private func showUnpreviewable(_ name: String) {
        content = .message(String(localized: "“\(name)” can’t be previewed."), actions: [])
    }

    // MARK: - Actions

    func perform(_ action: PreviewAction) {
        switch action {
        case .showSource(let file):
            work?.cancel()
            let generation = generation
            let selection = model.selection
            work = Task { [weak self] in
                let text: String
                do {
                    text = try await MarkdownPreviewRenderer.sourceText(of: file)
                } catch {
                    guard let self, isCurrent(generation, selection) else { return }
                    return showUnpreviewable(file.lastPathComponent)
                }
                guard let self, isCurrent(generation, selection) else { return }
                content = .source(text, file: file)
            }
        }
    }

    // MARK: - Item lookup

    /// The selected item: a row of the listed folder, else (an inline-expanded row) loaded from disk or,
    /// inside an archive, from its parent's listing. Nil when it is gone.
    private func item(for url: URL, inArchive: Bool) async -> FileItem? {
        let path = url.standardizedFileURL.path
        if let item = model.items.first(where: { $0.url.standardizedFileURL.path == path }) { return item }
        if inArchive {
            let siblings = try? await model.children(of: url.deletingLastPathComponent())
            return siblings?.first { $0.url.standardizedFileURL.path == path }
        }
        return await Self.loadItem(url)
    }

    @concurrent
    private static func loadItem(_ url: URL) async -> FileItem? {
        try? FileItem.load(url)
    }

    // MARK: - Header

    private static func header(for item: FileItem, icon: NSImage) -> PreviewHeader {
        var detail = item.kind
        if !item.isDirectory, let size = item.size {
            let text = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            detail = detail.isEmpty ? text : "\(detail) — \(text)"
        }
        return PreviewHeader(
            icon: icon, name: item.name, detail: detail,
            modified: item.dateModified?.formatted(date: .abbreviated, time: .shortened))
    }

    /// The icon of the item's type (no file-system access); used for archive entries and until the
    /// file's own icon is loaded.
    private static func typeIcon(for item: FileItem) -> NSImage {
        let type: UTType =
            if item.isDirectory { .folder }
            else if item.isSymlink { .symbolicLink }
            else { UTType(filenameExtension: item.url.pathExtension) ?? .data }
        return sized(NSWorkspace.shared.icon(for: type))
    }

    /// `NSWorkspace.icon(forFile:)` touches the disk (and can stall on network volumes): off the main thread.
    @concurrent
    private static func fileIcon(for url: URL) async -> NSImage {
        sized(NSWorkspace.shared.icon(forFile: url.path))
    }

    /// A copy (NSWorkspace may hand out shared instances) at the header's size.
    nonisolated private static func sized(_ image: NSImage) -> NSImage {
        let icon = image.copy() as? NSImage ?? NSImage()
        icon.size = headerIconSize
        return icon
    }
}
