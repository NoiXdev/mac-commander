import Foundation

public enum PaneTransferKind: Equatable, Sendable {
    case copy, move
    case extract(archive: URL)
}

/// A copy/move/extract between the two panes, proposed to the user in a sheet before it runs.
public struct PaneTransferRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: PaneTransferKind
    /// Top-level selection, sorted by path.
    public let sources: [URL]
    /// Inner paths for `.extract`, in the order of `sources`; empty otherwise.
    public let entries: [String]
    /// Proposed destination: the other pane's folder.
    public let destination: URL

    public init(
        id: UUID = UUID(), kind: PaneTransferKind, sources: [URL], entries: [String] = [], destination: URL
    ) {
        self.id = id
        self.kind = kind
        self.sources = sources
        self.entries = entries
        self.destination = destination
    }

    public var title: String {
        let single = sources.count == 1 ? sources[0].lastPathComponent : nil
        switch (kind, single) {
        case (.copy, let name?): return L10n.format("browser.transfer.copyOne", "Copy “%@” to:", name)
        case (.copy, nil): return L10n.plural("browser.transfer.copy", count: sources.count, one: "Copy 1 item to:", other: "Copy %lld items to:")
        case (.move, let name?): return L10n.format("browser.transfer.moveOne", "Move “%@” to:", name)
        case (.move, nil): return L10n.plural("browser.transfer.move", count: sources.count, one: "Move 1 item to:", other: "Move %lld items to:")
        case (.extract, let name?): return L10n.format("browser.transfer.extractOne", "Extract “%@” to:", name)
        case (.extract, nil): return L10n.plural("browser.transfer.extract", count: sources.count, one: "Extract 1 item to:", other: "Extract %lld items to:")
        }
    }
}

public enum PaneTransfer {
    /// Drops every URL that has an ancestor in the set; sorted by standardized path.
    public static func topLevel(_ urls: Set<URL>) -> [URL] {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        return urls.map { $0.standardizedFileURL }
            .filter { url in
                var parent = (url.path as NSString).deletingLastPathComponent
                while !parent.isEmpty && parent != "/" {
                    if paths.contains(parent) { return false }
                    parent = (parent as NSString).deletingLastPathComponent
                }
                return true
            }
            .sorted { $0.path < $1.path }
    }

    /// Trims whitespace; "~" and "~/…" expand against `home`; must then start with "/"; returns the
    /// standardized directory URL, or nil (empty, relative, "~user").
    public static func parseDestination(_ text: String, home: URL) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if trimmed == "~" {
            path = home.path
        } else if trimmed.hasPrefix("~/") {
            path = home.path + "/" + trimmed.dropFirst(2)
        } else {
            path = trimmed
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

extension PaneLayout {
    /// nil (caller beeps) when: not dual, no `transferTarget`, empty selection, or move from an archive.
    /// Copy from an archive becomes `.extract(archive:)`.
    public func transferRequest(move: Bool) -> PaneTransferRequest? {
        guard isDual, let destination = transferTarget else { return nil }
        let sources = PaneTransfer.topLevel(active.selection)
        guard !sources.isEmpty else { return nil }
        if let archive = active.archiveLocation?.archive {
            guard !move else { return nil }
            let entries = sources.compactMap { ArchivePath.inner(of: $0, in: archive) }
            guard entries.count == sources.count else { return nil }
            return PaneTransferRequest(
                kind: .extract(archive: archive), sources: sources, entries: entries, destination: destination)
        }
        return PaneTransferRequest(kind: move ? .move : .copy, sources: sources, destination: destination)
    }

    /// Sets `pendingTransfer` from `transferRequest(move:)`; false when there is none.
    @discardableResult
    public func requestTransfer(move: Bool) -> Bool {
        guard let request = transferRequest(move: move) else { return false }
        pendingTransfer = request
        return true
    }
}
