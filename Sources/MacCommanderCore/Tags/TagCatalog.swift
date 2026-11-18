import Foundation
import Observation

/// Every tag in use: Finder's standard tags, then the custom tags Spotlight finds on files in the home
/// folder, plus those set in-app (`noteUsed`, shown at once). Feeds the sidebar's Tags section and the
/// Tags menu.
///
/// The live `NSMetadataQuery` lives on the main actor (it needs a run loop) and only asks for the distinct
/// tag names (`valueLists`), not the files. Spotlight knows names only, so a custom tag's color comes from
/// `noteUsed` (Ruling P6-4); until then it is uncolored. `merge` is pure and unit-tested.
@MainActor @Observable
public final class TagCatalog {
    public static let shared = TagCatalog()
    /// Spotlight's tag-names attribute (`kMDItemUserTags`).
    private static let attribute = "kMDItemUserTags"

    public private(set) var tags: [FileTag] = []

    @ObservationIgnored private var standard: [FileTag] = []
    /// Tag names found by Spotlight.
    @ObservationIgnored private var inUse: [String] = []
    /// Tags set in-app, with their colors.
    @ObservationIgnored private var known: [FileTag] = []
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {}

    /// Starts the live query (once; later calls do nothing).
    public func start(standard: [FileTag]) {
        guard query == nil else { return }
        self.standard = standard
        recompute()
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(fromMetadataQueryString: "kMDItemUserTags == \"*\"")
        query.valueListAttributes = [Self.attribute]
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 1
        let center = NotificationCenter.default
        observers = [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate].map { name in
            center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readValueLists() }
            }
        }
        self.query = query
        query.start()
    }

    /// Records a tag set in-app, so it (and its color) shows at once.
    public func noteUsed(_ tag: FileTag) {
        known.removeAll { $0 == tag }
        known.append(tag)
        recompute()
    }

    /// The standard tags in the given order, then the custom names that aren't standard (case-insensitive,
    /// the first spelling kept), sorted with `localizedStandardCompare`. A custom tag takes its color from
    /// `known` when there, else `.none`.
    public static func merge(standard: [FileTag], inUse: [String], known: [FileTag]) -> [FileTag] {
        var seen = Set(standard)
        var custom: [FileTag] = []
        for name in inUse {
            let colored = known.first { $0 == FileTag(name: name, color: .none) }
            let tag = FileTag(name: name, color: colored?.color ?? .none)
            if seen.insert(tag).inserted { custom.append(tag) }
        }
        custom.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return standard + custom
    }

    private func readValueLists() {
        guard let query else { return }
        query.disableUpdates()
        let values = query.valueLists[Self.attribute] ?? []
        query.enableUpdates()
        inUse = values.compactMap { $0.value as? String }
        recompute()
    }

    private func recompute() {
        // Tags set in-app count as in use even before Spotlight indexes them.
        let merged = Self.merge(standard: standard, inUse: inUse + known.map(\.name), known: known)
        // Only on a real change (exact spelling and color), so observers don't redraw on every update.
        let key = { (tags: [FileTag]) in tags.map { "\($0.name)\n\($0.rawColor)" } }
        if key(merged) != key(tags) { tags = merged }
    }
}
