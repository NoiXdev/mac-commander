import Foundation
import Observation

/// Every tag in use: Finder's standard tags, then the custom tags Spotlight finds on files in the home
/// folder, plus those set or created in-app (`noteUsed`, shown at once). Feeds the sidebar's Tags section,
/// the Tags menu and Settings ▸ Tags.
///
/// The live `NSMetadataQuery` lives on the main actor (it needs a run loop) and only asks for the distinct
/// tag names (`valueLists`), not the files. Spotlight knows names only, so a custom tag's color comes from
/// `noteUsed` (Ruling P6-4); until then it is uncolored. The tags set in-app are kept across launches through
/// `onKnownChange` (`Preferences.knownTags`). `merge` is pure and unit-tested.
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
    /// Renamed or deleted names (lowercased), hidden while Spotlight still reports them from its old index.
    @ObservationIgnored private var forgotten: Set<String> = []
    /// Called with the tags set in-app whenever they change, to persist them.
    @ObservationIgnored public var onKnownChange: (@MainActor ([FileTag]) -> Void)?
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {}

    /// Starts the live query (once; later calls do nothing). `known`: the tags set in-app in earlier launches.
    public func start(standard: [FileTag], known: [FileTag] = []) {
        guard query == nil else { return }
        self.standard = standard
        self.known = known
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

    /// Records a tag set or created in-app, so it (and its color) shows at once.
    public func noteUsed(_ tag: FileTag) {
        known.removeAll { $0 == tag }
        known.append(tag)
        forgotten.remove(tag.name.lowercased())
        recompute()
        onKnownChange?(known)
    }

    /// Drops a renamed or deleted tag. Spotlight may report its name for a while after the files changed: it
    /// stays hidden until Spotlight stops reporting it.
    public func forget(_ tag: FileTag) {
        known.removeAll { $0 == tag }
        forgotten.insert(tag.name.lowercased())
        recompute()
        onKnownChange?(known)
    }

    /// Whether `tag` is one of Finder's standard color tags (those can't be renamed, recolored or deleted).
    public func isStandard(_ tag: FileTag) -> Bool {
        standard.contains(tag)
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
        updateInUse(values.compactMap { $0.value as? String })
    }

    /// Spotlight's latest tag names. A forgotten name it no longer reports is done with.
    func updateInUse(_ names: [String]) {
        inUse = names
        forgotten.formIntersection(names.map { $0.lowercased() })
        recompute()
    }

    private func recompute() {
        // Tags set in-app count as in use even before Spotlight indexes them.
        let reported = inUse.filter { !forgotten.contains($0.lowercased()) }
        let merged = Self.merge(standard: standard, inUse: reported + known.map(\.name), known: known)
        // Only on a real change (exact spelling and color), so observers don't redraw on every update.
        let key = { (tags: [FileTag]) in tags.map { "\($0.name)\n\($0.rawColor)" } }
        if key(merged) != key(tags) { tags = merged }
    }
}
