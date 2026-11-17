import Foundation
import Testing

@testable import MacCommanderCore

/// Polls until `condition` holds or the deadline passes.
@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
}

/// A share named "Media" that may be mounted at `tmp/share` or (after a remount) at `tmp/share-1`.
@MainActor
@Suite struct BrowserModelShareTests {
    private let shareID = UUID()

    private func makeStore() -> ViewSettingsStore {
        ViewSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    /// Resolves paths under any of `mountPoints` to the "Media" share, like `ShareManager.mountPoint(containing:)`.
    private func resolver(_ mountPoints: [URL]) -> @MainActor (URL) -> (id: UUID, name: String, mountPoint: URL)? {
        let id = shareID
        return { url in
            let path = url.standardizedFileURL.path
            for mountPoint in mountPoints {
                let root = mountPoint.standardizedFileURL.path
                if path == root || path.hasPrefix(root + "/") { return (id, "Media", mountPoint) }
            }
            return nil
        }
    }

    @Test func vanishedShareFolderShowsDisconnected() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let sub = try dir.folder("share/sub")
        try dir.file("share/sub/a.txt")
        let model = BrowserModel(start: share, settings: makeStore())
        model.shareResolver = resolver([share])
        await model.reload()
        await model.navigate(to: sub)
        let canGoBack = model.history.canGoBack
        #expect(model.items.count == 1)

        try FileManager.default.removeItem(at: sub)
        await model.reload()

        #expect(model.loadError == .shareDisconnected(name: "Media"))
        #expect(samePath(model.currentURL, sub))
        #expect(model.history.canGoBack == canGoBack)
        #expect(model.items.isEmpty)
        #expect(model.listedURL == nil)
        #expect(model.disconnectedShare?.id == shareID)
        #expect(model.disconnectedShare.map { samePath($0.mountPoint, share) } == true)
        // A watcher event or a refresh must not move the window to an ancestor either.
        try await Task.sleep(for: .milliseconds(200))
        #expect(samePath(model.currentURL, sub))
    }

    @Test func nonShareFolderStillFallsBack() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let local = try dir.folder("local")
        let sub = try dir.folder("local/sub")
        let model = BrowserModel(start: local, settings: makeStore())
        model.shareResolver = resolver([share])
        await model.reload()
        await model.navigate(to: sub)

        try FileManager.default.removeItem(at: sub)
        await model.reload()

        #expect(samePath(model.currentURL, local))
        #expect(model.loadError == nil)
        #expect(model.disconnectedShare == nil)
    }

    @Test func reconnectedRewritesMountPrefix() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let sub = try dir.folder("share/sub")
        let model = BrowserModel(start: share, settings: makeStore())
        let newShare = dir.url.appendingPathComponent("share-1", isDirectory: true)
        model.shareResolver = resolver([share, newShare])
        await model.reload()
        await model.navigate(to: sub)

        // The share comes back under another mount point name.
        try FileManager.default.moveItem(at: share, to: newShare)
        try dir.file("share-1/sub/b.txt")
        await model.reload()
        #expect(model.loadError == .shareDisconnected(name: "Media"))

        await model.reconnected(oldMountPoint: share, newMountPoint: newShare)

        #expect(samePath(model.currentURL, newShare.appendingPathComponent("sub")))
        #expect(model.items.map(\.name) == ["b.txt"])
        #expect(model.loadError == nil)
        #expect(model.disconnectedShare == nil)
        // Back still leads to the share's root, under its new name.
        await model.goBack()
        #expect(samePath(model.currentURL, newShare))
    }

    @Test func autoReconnectNotificationReloads() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let sub = try dir.folder("share/sub")
        let model = BrowserModel(start: share, settings: makeStore())
        let newShare = dir.url.appendingPathComponent("share-1", isDirectory: true)
        model.shareResolver = resolver([share, newShare])
        await model.reload()
        await model.navigate(to: sub)

        try FileManager.default.moveItem(at: share, to: newShare)
        try dir.file("share-1/sub/c.txt")
        await model.reload()
        #expect(model.loadError == .shareDisconnected(name: "Media"))

        NotificationCenter.default.post(
            name: ShareManager.didConnectNotification, object: nil,
            userInfo: ["mountPoint": newShare, "shareID": shareID])

        #expect(await waitUntil { model.items.map(\.name) == ["c.txt"] })
        #expect(samePath(model.currentURL, newShare.appendingPathComponent("sub")))
        #expect(model.loadError == nil)
    }

    @Test func connectOfAnotherShareIsIgnored() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let sub = try dir.folder("share/sub")
        let model = BrowserModel(start: share, settings: makeStore())
        model.shareResolver = resolver([share])
        await model.reload()
        await model.navigate(to: sub)
        try FileManager.default.removeItem(at: sub)
        await model.reload()

        NotificationCenter.default.post(
            name: ShareManager.didConnectNotification, object: nil,
            userInfo: ["mountPoint": dir.url, "shareID": UUID()])
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.loadError == .shareDisconnected(name: "Media"))
        #expect(samePath(model.currentURL, sub))
    }
}
