import Foundation

/// Finds the files that carry a tag.
public protocol TaggedFileFinding: Sendable {
    func files(taggedWith name: String) async -> [URL]
}

/// Spotlight, in the home folder (as `TagCatalog` looks): a file Spotlight hasn't indexed, or one outside the
/// home folder, isn't found. Tag names compare case-insensitively, as Finder's do.
public struct SpotlightTagFinder: TaggedFileFinding {
    public init() {}

    public func files(taggedWith name: String) async -> [URL] {
        await MainActor.run { SpotlightSearchOnce() }.run(
            NSPredicate(format: "%K ==[c] %@", "kMDItemUserTags", name))
    }
}

/// One gathering pass of an `NSMetadataQuery` (it needs the main run loop), returning the result paths.
@MainActor
private final class SpotlightSearchOnce {
    private var query: NSMetadataQuery?
    private var observer: (any NSObjectProtocol)?
    private var continuation: CheckedContinuation<[URL], Never>?

    func run(_ predicate: NSPredicate) async -> [URL] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let query = NSMetadataQuery()
            query.predicate = predicate
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
            self.query = query
            if !query.start() { finish() }
        }
    }

    private func finish() {
        guard let query, let continuation else { return }
        query.stop()
        let urls = query.results.compactMap { item in
            ((item as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String)
                .map { URL(fileURLWithPath: $0) }
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.query = nil
        self.observer = nil
        self.continuation = nil
        continuation.resume(returning: urls)
    }
}

public enum TagEditError: LocalizedError, Equatable {
    /// The files that couldn't be changed; every other file was.
    case filesNotChanged([URL])
    case standardTag

    public var errorDescription: String? {
        switch self {
        case .filesNotChanged(let urls):
            String(localized: "\(urls.count) files couldn't be changed.")
        case .standardTag:
            String(localized: "Finder's color tags can't be renamed, recolored or deleted.")
        }
    }

    public var recoverySuggestion: String? {
        guard case .filesNotChanged(let urls) = self else { return nil }
        return urls.prefix(5).map(\.path).joined(separator: "\n")
    }
}

/// Creates, renames, recolors and deletes tags: on every file that carries the tag (`finder`), in the catalog,
/// and in the sidebar's hidden tags. Finder's standard color tags are left alone.
@MainActor
public final class TagEditor {
    private let catalog: TagCatalog
    private let preferences: PreferencesStore
    private let finder: any TaggedFileFinding

    public init(catalog: TagCatalog, preferences: PreferencesStore, finder: any TaggedFileFinding) {
        self.catalog = catalog
        self.preferences = preferences
        self.finder = finder
    }

    public func isEditable(_ tag: FileTag) -> Bool {
        !catalog.isStandard(tag)
    }

    /// The files that carry the tag.
    public func files(with tag: FileTag) async -> [URL] {
        await finder.files(taggedWith: tag.name)
    }

    /// A tag no file has yet; it shows in the sidebar and the Tags menu. An existing tag of that name gets the
    /// color instead.
    public func create(_ tag: FileTag) async throws {
        if let existing = catalog.tags.first(where: { $0 == tag }) {
            try await recolor(existing, to: tag.color)
        } else {
            catalog.noteUsed(tag)
        }
    }

    public func recolor(_ tag: FileTag, to color: TagColor) async throws {
        try await replace(tag, with: FileTag(name: tag.name, color: color))
    }

    /// A new name for the tag. Renaming it to another tag's name merges the two, in that tag's color.
    public func rename(_ tag: FileTag, to name: String) async throws {
        let name = TagStore.sanitizedName(name)
        guard !name.isEmpty, name != tag.name else { return }
        let other = catalog.tags.first { $0 == FileTag(name: name, color: .none) && $0 != tag }
        if let other, catalog.isStandard(other) { throw TagEditError.standardTag }
        try await replace(tag, with: other ?? FileTag(name: name, color: tag.color))
    }

    /// Removes the tag from every file and from the catalog.
    public func delete(_ tag: FileTag) async throws {
        guard isEditable(tag) else { throw TagEditError.standardTag }
        try await change(.remove(tag), taggedWith: tag)
        catalog.forget(tag)
        preferences.preferences.hiddenTags = preferences.preferences.hiddenTags.filter {
            $0.lowercased() != tag.name.lowercased()
        }
    }

    private func replace(_ tag: FileTag, with new: FileTag) async throws {
        guard isEditable(tag) else { throw TagEditError.standardTag }
        try await change(.rename(tag, to: new), taggedWith: tag)
        if new.name.lowercased() != tag.name.lowercased() {
            catalog.forget(tag)
            var hidden = preferences.preferences.hiddenTags
            if hidden.contains(where: { $0.lowercased() == tag.name.lowercased() }) {
                hidden = hidden.filter { $0.lowercased() != tag.name.lowercased() }
                hidden.insert(new.name)
                preferences.preferences.hiddenTags = hidden
            }
        }
        catalog.noteUsed(new)
    }

    /// Applies `change` to every file with the tag, going on past a file that fails. The catalog is only
    /// updated by the caller once every file has changed: a file that kept the old tag still shows it.
    private func change(_ change: TagChange, taggedWith tag: FileTag) async throws {
        var failed: [URL] = []
        for url in await finder.files(taggedWith: tag.name) {
            do {
                try await TagStore.setTags(change, on: [url])
            } catch {
                failed.append(url)
            }
        }
        if !failed.isEmpty { throw TagEditError.filesNotChanged(failed) }
    }
}
