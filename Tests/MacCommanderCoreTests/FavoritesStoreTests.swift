import Foundation
import Testing

@testable import MacCommanderCore

@MainActor
@Suite struct FavoritesStoreTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func defaultsWhenEmpty() {
        withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)
            #expect(store.favorites.count == 5)
            #expect(store.favorites.first?.url.path == FileManager.default.homeDirectoryForCurrentUser.path)
            #expect(store.favorites.last?.url.path == "/Applications")
            #expect(defaults.object(forKey: FavoritesStore.key) == nil)
        }
    }

    @Test func addRemovePersist() throws {
        let temp = try TemporaryDirectory()
        let a = try temp.folder("a")
        withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)
            store.add(a)
            #expect(store.favorites.last?.url.path == a.path)

            let reloaded = FavoritesStore(defaults: defaults)
            #expect(reloaded.favorites.map(\.url.path) == store.favorites.map(\.url.path))

            reloaded.remove(a)
            #expect(!reloaded.favorites.contains { $0.url.path == a.path })
            let again = FavoritesStore(defaults: defaults)
            #expect(!again.favorites.contains { $0.url.path == a.path })
            #expect(again.favorites.count == 5)
        }
    }

    @Test func addExistingMovesInsteadOfDuplicating() throws {
        let temp = try TemporaryDirectory()
        let a = try temp.folder("a")
        let b = try temp.folder("b")
        withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)
            store.add(a)
            store.add(b)
            store.add(a, at: 0)
            #expect(store.favorites.count == 7)
            #expect(store.favorites.first?.url.path == a.path)
            #expect(store.favorites.filter { $0.url.path == a.path }.count == 1)
            // Trailing slash form is the same entry.
            store.add(URL(fileURLWithPath: a.path + "/", isDirectory: true))
            #expect(store.favorites.count == 7)
            #expect(store.favorites.last?.url.path == a.path)
        }
    }

    @Test func missingFavoriteKeptWithExistsFalse() throws {
        let temp = try TemporaryDirectory()
        let a = try temp.folder("gone")
        try withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)
            store.add(a)
            #expect(store.favorites.last?.exists == true)
            try FileManager.default.removeItem(at: a)
            store.refreshExistence()
            #expect(store.favorites.last?.url.path == a.path)
            #expect(store.favorites.last?.exists == false)
        }
    }

    @Test func moveReorders() {
        withDefaults { defaults in
            let store = FavoritesStore(defaults: defaults)
            let first = store.favorites[0].url.path
            store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
            #expect(store.favorites[2].url.path == first)
            let reloaded = FavoritesStore(defaults: defaults)
            #expect(reloaded.favorites[2].url.path == first)
        }
    }

    @Test func badStoredDataUsesDefaultsWithoutOverwriting() {
        withDefaults { defaults in
            defaults.set("not an array", forKey: FavoritesStore.key)
            let store = FavoritesStore(defaults: defaults)
            #expect(store.favorites.count == 5)
            #expect(defaults.string(forKey: FavoritesStore.key) == "not an array")
        }
    }

    @Test func storedPathsAreCleanedAndDeduplicated() {
        withDefaults { defaults in
            defaults.set(["", "/tmp", "/tmp/", "relative"], forKey: FavoritesStore.key)
            let store = FavoritesStore(defaults: defaults)
            #expect(store.favorites.map(\.url.path) == ["/tmp"])
        }
    }
}
