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
    private let defaults = TemporaryDefaults()

    private let shareID = UUID()

    private func makeStore() -> ViewSettingsStore {
        ViewSettingsStore(defaults: defaults.make())
    }

    /// Resolves paths under any of `mountPoints` to the "Media" share, like `ShareManager.mountPoint(containing:)`.
    /// `isConnected` is what the manager would report (false: the share dropped). `isKnownDisconnected`: the
    /// manager has checked the share and it isn't connected.
    private func resolver(
        _ mountPoints: [URL], isConnected: Bool = false, isKnownDisconnected: Bool = false
    ) -> @MainActor (URL) -> ShareLookup? {
        let id = shareID
        return { url in
            let path = url.standardizedFileURL.path
            for mountPoint in mountPoints {
                let root = mountPoint.standardizedFileURL.path
                if path == root || path.hasPrefix(root + "/") {
                    return (id, "Media", mountPoint, isConnected, isKnownDisconnected)
                }
            }
            return nil
        }
    }

    @Test func knownDisconnectedShareShowsPlaceholderWithoutStat() async throws {
        let dir = try TemporaryDirectory()
        let local = try dir.folder("local")
        let share = try dir.folder("share")
        let sub = try dir.folder("share/sub")
        // Any stat under the share would hang like a dead mount.
        let prefix = share.standardizedFileURL.path
        PathQueries.setTestDelay(5, forPathsUnder: prefix)
        defer { PathQueries.setTestDelay(nil, forPathsUnder: prefix) }
        let model = BrowserModel(start: local, settings: makeStore())
        model.shareResolver = resolver([share], isKnownDisconnected: true)
        var dropped: [UUID] = []
        model.shareDropped = { dropped.append($0) }
        await model.reload()

        let clock = ContinuousClock()
        let start = clock.now
        #expect(await model.navigate(to: sub) == .done)
        #expect(clock.now - start < .seconds(2))
        #expect(model.loadError == .shareDisconnected(name: "Media"))
        #expect(model.disconnectedShare?.id == shareID)
        #expect(samePath(model.currentURL, sub))
        #expect(!model.isLoading)
        #expect(PathQueries.testLookupCount(forPathsUnder: prefix) == 0)
        #expect(dropped == [shareID])

        // A reload doesn't stat either.
        await model.reload()
        #expect(PathQueries.testLookupCount(forPathsUnder: prefix) == 0)
        #expect(model.loadError == .shareDisconnected(name: "Media"))
    }

    @Test func missingPathOnUnconnectedShareShowsPlaceholderNotMissing() async throws {
        let dir = try TemporaryDirectory()
        let local = try dir.folder("local")
        // The share's last mount point; nothing is mounted there now (the manager is still checking).
        let share = dir.url.appendingPathComponent("share", isDirectory: true)
        let favorite = share.appendingPathComponent("Projects", isDirectory: true)
        let model = BrowserModel(start: local, settings: makeStore())
        model.shareResolver = resolver([share])
        await model.reload()

        #expect(await model.navigate(to: favorite) == .done)
        #expect(model.loadError == .shareDisconnected(name: "Media"))
        #expect(samePath(model.currentURL, favorite))
        #expect(model.history.canGoBack)
    }

    @Test func missingPathOnConnectedShareIsMissing() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let model = BrowserModel(start: share, settings: makeStore())
        model.shareResolver = resolver([share], isConnected: true)
        await model.reload()

        #expect(await model.navigate(to: share.appendingPathComponent("gone")) == .missing)
        #expect(model.loadError == nil)
        #expect(samePath(model.currentURL, share))
    }

    @Test func deletedSubfolderOnConnectedShareFallsBack() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let sub = try dir.folder("share/sub")
        let model = BrowserModel(start: share, settings: makeStore())
        model.shareResolver = resolver([share], isConnected: true)
        await model.reload()
        await model.navigate(to: sub)

        try FileManager.default.removeItem(at: sub)
        await model.reload()

        #expect(samePath(model.currentURL, share))
        #expect(model.loadError == nil)
        #expect(model.disconnectedShare == nil)
    }

    @Test func connectedShareWhoseMountPointIsGoneShowsDisconnected() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let sub = try dir.folder("share/sub")
        let model = BrowserModel(start: share, settings: makeStore())
        model.shareResolver = resolver([share], isConnected: true)
        await model.reload()
        await model.navigate(to: sub)

        // The manager hasn't noticed yet, but the mount point itself is gone.
        try FileManager.default.removeItem(at: share)
        await model.reload()

        #expect(model.loadError == .shareDisconnected(name: "Media"))
        #expect(samePath(model.currentURL, sub))
    }

    @Test func connectWithoutPlaceholderIsLeftToTheCaller() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let sub = try dir.folder("share/sub")
        let model = BrowserModel(start: share, settings: makeStore())
        model.shareResolver = resolver([share], isConnected: true)
        await model.reload()
        await model.navigate(to: sub)

        // Already inside the share, but no placeholder: the UI navigates to the mount point as usual.
        #expect(await model.shareDidConnect(id: shareID, mountPoint: share) == false)
    }

    @Test func connectAfterNotificationRecoveryKeepsTheFolder() async throws {
        let dir = try TemporaryDirectory()
        let share = try dir.folder("share")
        let sub = try dir.folder("share/sub")
        let model = BrowserModel(start: share, settings: makeStore())
        let newShare = dir.url.appendingPathComponent("share-1", isDirectory: true)
        model.shareResolver = resolver([share, newShare])
        await model.reload()
        await model.navigate(to: sub)
        try FileManager.default.moveItem(at: share, to: newShare)
        await model.reload()
        #expect(model.disconnectedShare != nil)

        // The notification recovers first; the UI's connect flow for the same connect must not navigate away.
        NotificationCenter.default.post(
            name: ShareManager.didConnectNotification, object: nil,
            userInfo: ["mountPoint": newShare, "shareID": shareID])
        #expect(await waitUntil { model.disconnectedShare == nil })
        #expect(await model.shareDidConnect(id: shareID, mountPoint: newShare))
        #expect(samePath(model.currentURL, newShare.appendingPathComponent("sub")))

        // After the user navigates, a later connect is the caller's again.
        await model.goBack()
        #expect(await model.shareDidConnect(id: shareID, mountPoint: newShare) == false)
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
