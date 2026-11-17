import Foundation
import Observation

public struct SidebarLocation: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: URL { url }
    public let name: String
    public let exists: Bool
}

@MainActor @Observable
public final class FavoritesStore {
    static let key = "favorites.v1"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager

    public private(set) var favorites: [SidebarLocation] = []

    public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        if let paths = defaults.object(forKey: Self.key) as? [String] {
            // Skip entries that can't be a favorite (empty or relative paths would resolve against
            // the working directory) and duplicates, which would break the sidebar's identities.
            var seen = Set<String>()
            favorites = paths.compactMap { path in
                guard path.hasPrefix("/") else { return nil }
                let url = URL(fileURLWithPath: path)
                guard seen.insert(Self.normalizedPath(url)).inserted else { return nil }
                return location(for: url)
            }
        } else {
            // Absent or not a [String]: use defaults without touching the stored value.
            let home = fileManager.homeDirectoryForCurrentUser
            favorites = [
                home,
                home.appendingPathComponent("Desktop", isDirectory: true),
                home.appendingPathComponent("Documents", isDirectory: true),
                home.appendingPathComponent("Downloads", isDirectory: true),
                URL(fileURLWithPath: "/Applications", isDirectory: true),
            ].map { location(for: $0) }
        }
    }

    /// Adds `url`, or moves it to `index` (default: the end) if already present.
    public func add(_ url: URL, at index: Int? = nil) {
        let path = Self.normalizedPath(url)
        favorites.removeAll { Self.normalizedPath($0.url) == path }
        let target = min(max(index ?? favorites.count, 0), favorites.count)
        favorites.insert(location(for: url), at: target)
        persist()
    }

    public func remove(_ url: URL) {
        let path = Self.normalizedPath(url)
        favorites.removeAll { Self.normalizedPath($0.url) == path }
        persist()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.filter { favorites.indices.contains($0) }
        let moved = moving.map { favorites[$0] }
        let before = moving.filter { $0 < toOffset }.count
        for i in moving.reversed() { favorites.remove(at: i) }
        let target = min(max(toOffset - before, 0), favorites.count)
        favorites.insert(contentsOf: moved, at: target)
        persist()
    }

    /// Re-checks which favorites exist; missing ones stay listed. Does not persist.
    public func refreshExistence() {
        favorites = favorites.map { location(for: $0.url) }
    }

    private func location(for url: URL) -> SidebarLocation {
        let values = try? url.resourceValues(forKeys: [.localizedNameKey])
        return SidebarLocation(
            url: url,
            name: values?.localizedName ?? url.lastPathComponent,
            exists: fileManager.fileExists(atPath: url.path))
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func persist() {
        defaults.set(favorites.map { Self.normalizedPath($0.url) }, forKey: Self.key)
    }
}
