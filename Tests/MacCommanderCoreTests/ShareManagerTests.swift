import Foundation
import Testing

@testable import MacCommanderCore

// MARK: Fakes

/// Suspends callers until `release()`.
private actor MountGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private actor FakeVolumes: MountedVolumeLister {
    private(set) var mounts: [MountedShare] = []
    private(set) var listCount = 0

    func set(_ mounts: [MountedShare]) { self.mounts = mounts }
    func add(_ mount: MountedShare) { mounts.append(mount) }
    func remove(_ mountPoint: URL) { mounts.removeAll { $0.mountPoint == mountPoint } }

    private var gate: MountGate?
    func setGate(_ gate: MountGate?) { self.gate = gate }

    /// Returns the mounts as of the call, even when the gate holds the answer back.
    func mountedShares() async -> [MountedShare] {
        listCount += 1
        let snapshot = mounts
        if let gate { await gate.wait() }
        return snapshot
    }
}

/// Records its calls; a successful mount also shows up in `volumes`, like a real one would.
private actor FakeMounter: ShareMounter {
    struct Call: Equatable {
        let url: ShareURL
        let credentials: ShareCredentials
    }

    private let volumes: FakeVolumes
    private(set) var mounts: [Call] = []
    private(set) var unmounts: [(mountPoint: URL, force: Bool)] = []
    private var handler: @Sendable (ShareURL, ShareCredentials) -> Result<URL, MountError> = { url, _ in
        .success(URL(fileURLWithPath: "/Volumes/\(url.shareName)"))
    }
    private var gate: MountGate?

    init(volumes: FakeVolumes) { self.volumes = volumes }

    func setHandler(_ handler: @escaping @Sendable (ShareURL, ShareCredentials) -> Result<URL, MountError>) {
        self.handler = handler
    }

    func setGate(_ gate: MountGate?) { self.gate = gate }

    func mount(_ url: ShareURL, credentials: ShareCredentials) async throws(MountError) -> URL {
        mounts.append(Call(url: url, credentials: credentials))
        if let gate { await gate.wait() }
        switch handler(url, credentials) {
        case .success(let mountPoint):
            await volumes.add(MountedShare(mountPoint: mountPoint, url: url))
            return mountPoint
        case .failure(let error):
            throw error
        }
    }

    func unmount(_ mountPoint: URL, force: Bool) async throws(MountError) {
        unmounts.append((mountPoint, force))
        await volumes.remove(mountPoint)
    }
}

private actor FakeProber: ReachabilityProber {
    private var reachable: Set<String> = []
    private(set) var probeCount = 0
    private(set) var timeouts: [Duration] = []
    private var gate: MountGate?

    func set(_ host: String, reachable: Bool) {
        if reachable { self.reachable.insert(host) } else { self.reachable.remove(host) }
    }

    /// Host names no name lookup finds (e.g. OrbStack's "OrbStack" NFS server).
    private var unresolvable: Set<String> = []
    func set(_ host: String, resolvable: Bool) {
        if resolvable { unresolvable.remove(host) } else { unresolvable.insert(host) }
    }

    func resolves(host: String) async -> Bool { !unresolvable.contains(host) }

    /// NetBIOS names and the address each answers with (e.g. a home NAS no DNS or Bonjour lookup finds).
    private var netBIOS: [String: String] = [:]
    func set(_ name: String, netBIOSAddress: String?) { netBIOS[name] = netBIOSAddress }

    private(set) var netBIOSTimeouts: [Duration] = []

    func netBIOSAddress(of name: String, timeout: Duration) async -> String? {
        netBIOSTimeouts.append(timeout)
        return netBIOS[name]
    }

    func setGate(_ gate: MountGate?) { self.gate = gate }

    /// One gate per call, in call order (before the shared `gate`).
    private var callGates: [MountGate] = []
    func setCallGates(_ gates: [MountGate]) { callGates = gates }

    func isReachable(host: String, port: Int, timeout: Duration) async -> Bool {
        probeCount += 1
        timeouts.append(timeout)
        if !callGates.isEmpty { await callGates.removeFirst().wait() }
        if let gate { await gate.wait() }
        return reachable.contains(host)
    }
}

private actor FakeCredentials: CredentialStore {
    struct Saved: Equatable {
        let password: String
        let url: ShareURL
        let username: String
    }

    private var items: [String: String] = [:]
    private(set) var saves: [Saved] = []
    private(set) var deletes = 0

    private func key(_ url: ShareURL, _ username: String) -> String { "\(url.url.absoluteString)|\(username)" }

    func store(_ password: String, for url: ShareURL, username: String) { items[key(url, username)] = password }
    var itemCount: Int { items.count }

    func password(for url: ShareURL, username: String) async -> String? { items[key(url, username)] }

    func save(password: String, for url: ShareURL, username: String) async throws {
        saves.append(Saved(password: password, url: url, username: username))
        items[key(url, username)] = password
    }

    func delete(for url: ShareURL, username: String) async {
        deletes += 1
        items[key(url, username)] = nil
    }
}

/// A `sleep` that only returns when the test calls `fire()` (or throws when its task is cancelled).
private actor ManualSleeper {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<UUID> = []
    var sleeperCount: Int { waiters.count }
    private(set) var requested: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }

    func fire() {
        let pending = waiters
        waiters = [:]
        pending.values.forEach { $0.resume() }
    }
}

@MainActor
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<3000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

@MainActor
private final class Harness {
    let dir: TemporaryDirectory
    let store: ShareStore
    let volumes = FakeVolumes()
    let mounter: FakeMounter
    let prober = FakeProber()
    let credentials = FakeCredentials()
    let sleeper = ManualSleeper()
    let manager: ShareManager

    init(dir: TemporaryDirectory? = nil) throws {
        self.dir = try dir ?? TemporaryDirectory()
        store = ShareStore(fileURL: self.dir.url.appendingPathComponent("shares.json"))
        mounter = FakeMounter(volumes: volumes)
        let sleeper = sleeper
        manager = ShareManager(
            store: store, mounter: mounter, prober: prober, volumes: volumes, credentials: credentials,
            sleep: { try await sleeper.sleep($0) })
    }

    /// Adds a saved share with the given properties.
    @discardableResult
    func share(
        _ string: String, username: String? = nil, lastAuth: AuthMethod = .automatic, autoReconnect: Bool = true
    ) throws -> SavedShare {
        var share = store.add(try #require(ShareURL(string)), username: username)
        share.lastAuth = lastAuth
        share.autoReconnect = autoReconnect
        store.update(share)
        return share
    }

    func saved(_ id: UUID) -> SavedShare? { store.shares.first { $0.id == id } }

    /// A refresh pass plus the auto-reconnect mounts it started.
    func refresh() async {
        await manager.refreshAll()
        await manager.waitForPendingAttempts()
    }
}

private func url(_ string: String) throws -> ShareURL { try #require(ShareURL(string)) }
private func volume(_ path: String) -> URL { URL(fileURLWithPath: path) }

// MARK: Tests

@MainActor @Suite struct ShareManagerTests {
    @Test func classifiesConnectedAvailableUnreachable() async throws {
        let h = try Harness()
        let a = try h.share("smb://nas/A", autoReconnect: false)
        let b = try h.share("smb://nas/B", autoReconnect: false)
        let c = try h.share("smb://far/C", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: try url("smb://nas/A"))])

        await h.refresh()

        #expect(h.manager.status[a.id] == .connected(mountPoint: volume("/Volumes/A")))
        #expect(h.manager.status[b.id] == .available(needsSignIn: false))
        #expect(h.manager.status[c.id] == .unreachable)
        #expect(h.saved(a.id)?.lastMountPath == "/Volumes/A")
        #expect(await h.volumes.listCount == 1)
        // One probe per host:port, with the 3 s timeout.
        #expect(await h.prober.probeCount == 2)
        #expect(await h.prober.timeouts.allSatisfy { $0 == .seconds(3) })
        #expect(await h.mounter.mounts.isEmpty)
    }

    /// OrbStack mounts its NFS share itself, from a server name ("OrbStack") that no name lookup finds: it can't
    /// be probed over the network, so a mounted one is connected. SMB keeps the probe (a dead NAS's stale mount
    /// stays unreachable).
    @Test func mountedNFSShareWithUnresolvableHostIsConnected() async throws {
        let h = try Harness()
        let orb = try h.share("nfs://orbstack/OrbStack", autoReconnect: false)
        let nas = try h.share("smb://office-nas/Projekte", autoReconnect: false)
        await h.prober.set("orbstack", resolvable: false)
        await h.prober.set("office-nas", resolvable: false)
        await h.volumes.set([
            MountedShare(mountPoint: volume("/Users/me/OrbStack"), url: try url("nfs://orbstack/OrbStack")),
            MountedShare(mountPoint: volume("/Volumes/Projekte"), url: try url("smb://office-nas/Projekte")),
        ])

        await h.refresh()

        #expect(h.manager.status[orb.id] == .connected(mountPoint: volume("/Users/me/OrbStack")))
        #expect(h.manager.status[nas.id] == .unreachable)
    }

    /// A NAS saved by its bare name ("home-nas"), which DNS doesn't know: the SMB client finds it over Bonjour as
    /// "home-nas.local", so the probe goes there.
    @Test func smbShareWithBareNameIsProbedOverBonjour() async throws {
        let h = try Harness()
        let share = try h.share("smb://home-nas/data", autoReconnect: false)
        await h.prober.set("home-nas", resolvable: false)
        await h.prober.set("home-nas.local", reachable: true)

        await h.refresh()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        #expect(await h.manager.connect(share.id) == .connected(volume("/Volumes/data")))
    }

    /// A NAS known only by its NetBIOS name: neither DNS nor Bonjour finds it, but the SMB client does, so the
    /// probe goes to the address the NetBIOS lookup answers with, given the lookup's own longer timeout.
    @Test func smbShareWithNetBIOSNameIsProbedAtItsAddress() async throws {
        let h = try Harness()
        let share = try h.share("smb://home-nas/data", autoReconnect: false)
        await h.prober.set("home-nas", resolvable: false)
        await h.prober.set("home-nas.local", resolvable: false)
        await h.prober.set("home-nas", netBIOSAddress: "192.168.178.85")
        await h.prober.set("192.168.178.85", reachable: true)

        await h.refresh()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        #expect(await h.manager.connect(share.id) == .connected(volume("/Volumes/data")))
        // `smbutil lookup` takes about 7 s to answer for a real NAS.
        #expect(await h.prober.netBIOSTimeouts.allSatisfy { $0 >= .seconds(10) })
        #expect(await !h.prober.netBIOSTimeouts.isEmpty)
    }

    @Test func checkingOnlyOnFirstLoad() async throws {
        let h = try Harness()
        let a = try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        let gate = MountGate()
        await h.prober.setGate(gate)
        let first = Task { await h.refresh() }
        #expect(await eventually { await h.prober.probeCount == 1 })
        #expect(h.manager.status[a.id] == .checking)
        await gate.release()
        await first.value
        #expect(h.manager.status[a.id] == .available(needsSignIn: false))

        let gate2 = MountGate()
        await h.prober.setGate(gate2)
        await h.prober.set("nas", reachable: false)
        let second = Task { await h.refresh() }
        #expect(await eventually { await h.prober.probeCount == 2 })
        #expect(h.manager.status[a.id] == .available(needsSignIn: false))  // no flicker
        await gate2.release()
        await second.value
        #expect(h.manager.status[a.id] == .unreachable)
    }

    @Test func matchesMountedShareByURLNotPath() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Media")
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/Media-1"), url: try url("smb://NAS/media"))])

        await h.refresh()

        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/Media-1")))
        #expect(h.saved(share.id)?.lastMountPath == "/Volumes/Media-1")
        #expect(await h.mounter.mounts.isEmpty)
        #expect(h.manager.rememberPrompts.isEmpty)

        let hit = h.manager.mountPoint(containing: volume("/Volumes/Media-1/Movies/../Shows/a.mkv"))
        #expect(hit?.share.id == share.id)
        #expect(hit?.mountPoint == volume("/Volumes/Media-1"))
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Media-1"))?.share.id == share.id)
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Media-10/a")) == nil)
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Media/a")) == nil)
    }

    @Test func autoReconnectMountsAvailableShares() async throws {
        let h = try Harness()
        let withPassword = try h.share("smb://nas/Pw", username: "bob", lastAuth: .password)
        await h.credentials.store("secret", for: try url("smb://nas/Pw"), username: "bob")
        let manual = try h.share("smb://nas/Manual", autoReconnect: false)
        let guest = try h.share("smb://nas/Guest", lastAuth: .guest)
        let noStoredPassword = try h.share("smb://nas/NoPw", username: "eve", lastAuth: .password)
        await h.prober.set("nas", reachable: true)
        await h.mounter.setHandler { url, creds in
            if url.shareName == "Guest" && creds.guest { return .failure(.authenticationFailed) }
            return .success(URL(fileURLWithPath: "/Volumes/\(url.shareName)"))
        }

        await h.refresh()

        let calls = await h.mounter.mounts
        func creds(_ name: String) -> [ShareCredentials] {
            calls.filter { $0.url.shareName == name }.map(\.credentials)
        }
        #expect(creds("Pw") == [ShareCredentials(username: "bob", password: "secret")])
        #expect(creds("Manual").isEmpty)
        #expect(creds("Guest") == [.asGuest, .automatic])
        #expect(creds("NoPw") == [.automatic])

        #expect(h.manager.status[withPassword.id] == .connected(mountPoint: volume("/Volumes/Pw")))
        #expect(h.manager.status[manual.id] == .available(needsSignIn: false))
        #expect(h.manager.status[guest.id] == .connected(mountPoint: volume("/Volumes/Guest")))
        #expect(h.saved(withPassword.id)?.lastAuth == .password)
        #expect(h.saved(guest.id)?.lastAuth == .automatic)
        #expect(h.saved(noStoredPassword.id)?.lastAuth == .automatic)
        #expect(h.saved(guest.id)?.lastMountPath == "/Volumes/Guest")

        // Mounted now: the next pass mounts nothing.
        await h.refresh()
        #expect(await h.mounter.mounts.count == calls.count)
    }

    @Test func authFailureSetsNeedsSignInAndStopsRetrying() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Locked")
        await h.prober.set("nas", reachable: true)
        await h.mounter.setHandler { _, _ in .failure(.authenticationFailed) }

        await h.refresh()
        #expect(await h.mounter.mounts.count == 1)
        #expect(h.manager.status[share.id] == .available(needsSignIn: true))

        await h.refresh()
        await h.refresh()
        #expect(await h.mounter.mounts.count == 1)
        #expect(h.manager.status[share.id] == .available(needsSignIn: true))

        // A user click still tries, and reports the need to sign in.
        #expect(await h.manager.connect(share.id) == .needsSignIn)

        // An edit clears the flag; auto-reconnect resumes.
        h.manager.clearSignInFlag(share.id)
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        let before = await h.mounter.mounts.count
        await h.refresh()
        #expect(await h.mounter.mounts.count == before + 1)
    }

    @Test func signInSavesOnlyWhenRemembered() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Corp", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.mounter.setHandler { url, creds in
            creds.password == "right"
                ? .success(URL(fileURLWithPath: "/Volumes/\(url.shareName)")) : .failure(.authenticationFailed)
        }
        await h.refresh()
        #expect(await h.manager.connect(share.id) == .needsSignIn)
        #expect(h.manager.status[share.id] == .available(needsSignIn: true))

        let user = #"CORP\daniel"#
        let first = await h.manager.signIn(share.id, username: user, password: "right", remember: false)
        #expect(first == .connected(volume("/Volumes/Corp")))
        #expect(await h.credentials.saves.isEmpty)
        #expect(h.saved(share.id)?.username == user)
        #expect(h.saved(share.id)?.lastAuth == .automatic)
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/Corp")))
        #expect(await h.mounter.mounts.last?.credentials == ShareCredentials(username: user, password: "right"))

        try await h.manager.disconnect(share.id)
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        let second = await h.manager.signIn(share.id, username: user, password: "right", remember: true)
        #expect(second == .connected(volume("/Volumes/Corp")))
        #expect(await h.credentials.saves == [.init(password: "right", url: share.url, username: user)])
        #expect(h.saved(share.id)?.lastAuth == .password)

        try await h.manager.disconnect(share.id)
        let wrong = await h.manager.signIn(share.id, username: user, password: "wrong", remember: true)
        #expect(wrong == .needsSignIn)
        #expect(await h.credentials.saves.count == 1)
        #expect(h.manager.status[share.id] == .available(needsSignIn: true))
    }

    @Test func guestPath() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Public", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.mounter.setHandler { url, creds in
            creds.guest ? .success(URL(fileURLWithPath: "/Volumes/\(url.shareName)")) : .failure(.authenticationFailed)
        }
        await h.refresh()
        #expect(await h.manager.connect(share.id) == .needsSignIn)

        #expect(await h.manager.connectAsGuest(share.id) == .connected(volume("/Volumes/Public")))
        #expect(h.saved(share.id)?.lastAuth == .guest)
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/Public")))

        try await h.manager.disconnect(share.id)
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        #expect(await h.manager.connect(share.id) == .connected(volume("/Volumes/Public")))
        #expect(await h.mounter.mounts.last?.credentials == .asGuest)
    }

    @Test func concurrentConnectsShareOneAttempt() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Slow", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        let gate = MountGate()
        await h.mounter.setGate(gate)

        let manager = h.manager
        let first = Task { await manager.connect(share.id) }
        let second = Task { await manager.connect(share.id) }
        #expect(await eventually { await h.mounter.mounts.count == 1 })
        await Task.yield()
        await gate.release()
        let outcomes = [await first.value, await second.value]

        #expect(outcomes == [.connected(volume("/Volumes/Slow")), .connected(volume("/Volumes/Slow"))])
        #expect(await h.mounter.mounts.count == 1)
        // Already connected: no new attempt.
        #expect(await h.manager.connect(share.id) == .connected(volume("/Volumes/Slow")))
        #expect(await h.mounter.mounts.count == 1)
    }

    @Test func unreachableTimerOnlyWhileNeeded() async throws {
        let h = try Harness()
        let share = try h.share("smb://far/Data", autoReconnect: false)
        h.manager.start()
        defer { h.manager.stop() }

        #expect(await eventually { await h.sleeper.sleeperCount == 1 })
        #expect(h.manager.status[share.id] == .unreachable)
        #expect(await h.prober.probeCount == 1)
        #expect(await h.sleeper.requested == [.seconds(60)])

        // Re-arming never stacks timers.
        await h.manager.networkChanged()
        await h.manager.networkChanged()
        #expect(await h.prober.probeCount == 3)
        #expect(await h.sleeper.sleeperCount == 1)
        #expect(h.manager.isTimerRunning)

        // Still unreachable after 60 s: probed again, timer stays.
        await h.sleeper.fire()
        #expect(await eventually { await h.prober.probeCount == 4 })
        #expect(await eventually { await h.sleeper.sleeperCount == 1 })

        // Back: after the next tick the share is available and the timer stops.
        await h.prober.set("far", reachable: true)
        await h.sleeper.fire()
        #expect(await eventually { h.manager.status[share.id] == .available(needsSignIn: false) })
        #expect(await eventually { !h.manager.isTimerRunning })
        #expect(await h.prober.probeCount == 5)
        await h.sleeper.fire()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await h.prober.probeCount == 5)
        #expect(await h.sleeper.sleeperCount == 0)
    }

    @Test func networkFlappingCoalesces() async throws {
        let h = try Harness()
        try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        let gate = MountGate()
        await h.prober.setGate(gate)

        let manager = h.manager
        let calls = (0..<10).map { _ in Task { await manager.networkChanged() } }
        #expect(await eventually { await h.prober.probeCount == 1 })
        for _ in 0..<20 { await Task.yield() }
        await gate.release()
        for call in calls { await call.value }

        let passes = await h.volumes.listCount
        #expect(passes >= 1 && passes <= 2)
    }

    @Test func externalMountPromptsOnceAndRespectsDecline() async throws {
        let dir = try TemporaryDirectory()
        let h = try Harness(dir: dir)
        h.store.decline(try url("smb://old/Gone"))
        let x = MountedShare(mountPoint: volume("/Volumes/X"), url: try url("smb://srv/X"))
        let y = MountedShare(mountPoint: volume("/Volumes/Y"), url: try url("afp://srv/Y"))
        let gone = MountedShare(mountPoint: volume("/Volumes/Gone"), url: try url("smb://OLD/gone"))
        await h.volumes.set([x, y, gone])

        await h.manager.volumesChanged()
        #expect(h.manager.rememberPrompts == [x, y])
        #expect(await h.prober.probeCount == 0)
        await h.manager.volumesChanged()
        await h.refresh()
        #expect(h.manager.rememberPrompts == [x, y])

        h.manager.decline(y)
        #expect(h.manager.rememberPrompts == [x])
        #expect(h.store.isDeclined(try url("afp://srv/Y")))
        await h.manager.volumesChanged()
        #expect(h.manager.rememberPrompts == [x])

        h.manager.remember(x)
        #expect(h.manager.rememberPrompts.isEmpty)
        let saved = try #require(h.store.share(matching: x.url))
        #expect(h.manager.status[saved.id] == .connected(mountPoint: volume("/Volumes/X")))
        #expect(saved.lastMountPath == "/Volumes/X")
        await h.manager.volumesChanged()
        #expect(h.manager.rememberPrompts.isEmpty)

        // Shown once per session: unmounted and mounted again, still not re-prompted.
        let z = MountedShare(mountPoint: volume("/Volumes/Z"), url: try url("smb://srv/Z"))
        await h.volumes.set([z])
        await h.manager.volumesChanged()
        #expect(h.manager.rememberPrompts == [z])
        await h.volumes.set([])
        await h.manager.volumesChanged()
        await h.volumes.set([z])
        await h.manager.volumesChanged()
        #expect(h.manager.rememberPrompts == [z])

        // The next session respects the stored decline.
        await h.store.flush()
        let next = try Harness(dir: dir)
        await next.volumes.set([x, y, gone])
        await next.manager.volumesChanged()
        #expect(next.manager.rememberPrompts.isEmpty)
    }

    @Test func volumesChangedProbesOnlyForADroppedConnectedShare() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.refresh()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))

        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: share.url)])
        await h.manager.volumesChanged()
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))

        #expect(await h.prober.probeCount == 1)

        // Gone while connected: one probe decides between "ejected elsewhere" and "dropped".
        await h.volumes.set([])
        await h.manager.volumesChanged()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        #expect(await h.prober.probeCount == 2)
        #expect(await h.mounter.mounts.isEmpty)
    }

    @Test func droppedMountWithUnreachableServerIsUnreachable() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A")
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: share.url)])
        await h.refresh()
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))

        // The link dropped (the system unmounted the dead volume): not an eject in Finder.
        await h.prober.set("nas", reachable: false)
        await h.volumes.set([])
        await h.manager.volumesChanged()
        #expect(h.manager.status[share.id] == .unreachable)
        #expect(!h.manager.hasMountPoint(share.id))

        // So once the server is back, auto-reconnect mounts it again without waiting for a network change.
        await h.prober.set("nas", reachable: true)
        await h.refresh()
        #expect(await h.mounter.mounts.count == 1)
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))
    }

    @Test func connectWithStaleConnectedStatusProbes() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: share.url)])
        await h.refresh()
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))

        // The server went away; nothing has told the manager yet.
        await h.prober.set("nas", reachable: false)
        #expect(await h.manager.connect(share.id) == .unreachable)
        #expect(h.manager.status[share.id] == .unreachable)
        #expect(await h.prober.probeCount == 2)
        #expect(await h.mounter.mounts.isEmpty)
        // Still mounted as far as the manager knows: Disconnect can force-unmount it.
        #expect(h.manager.hasMountPoint(share.id))
    }

    @Test func connectWhenAlreadyMountedAdoptsTheVolume() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.refresh()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))

        // Mounted in Finder; the volume notification hasn't been handled yet.
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A-1"), url: share.url)])
        #expect(await h.manager.connect(share.id) == .connected(volume("/Volumes/A-1")))
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A-1")))
        #expect(await h.mounter.mounts.isEmpty)
    }

    @Test func alreadyMountedErrorAdoptsTheVolumeOrFails() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.refresh()
        let mountPoint = volume("/Volumes/A")
        // NetFS reports EEXIST: the share is mounted already.
        await h.mounter.setHandler { _, _ in .failure(.alreadyMounted) }
        // ...but no listed volume serves it.
        #expect(await h.manager.signIn(share.id, username: "bob", password: "pw", remember: false)
            == .failed("Already connected."))
        // Mounted elsewhere meanwhile: that volume is used.
        await h.volumes.set([MountedShare(mountPoint: mountPoint, url: share.url)])
        #expect(await h.manager.connectAsGuest(share.id) == .connected(mountPoint))
        #expect(h.manager.status[share.id] == .connected(mountPoint: mountPoint))
    }

    @Test func savedSubfolderMatchesTheShareRootMount() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Media/Movies/2024", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/Media"), url: try url("smb://NAS/media"))])

        await h.refresh()

        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/Media")))
        #expect(h.manager.rememberPrompts.isEmpty)
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Media/Movies/2024/a.mkv"))?.share.id == share.id)
        #expect(share.url.folder(atMountPoint: volume("/Volumes/Media")).path == "/Volumes/Media/Movies/2024")

        // A second saved folder in the same share: lookups pick the one whose folder contains the path.
        let other = try h.share("smb://nas/Media/Music", autoReconnect: false)
        await h.refresh()
        #expect(h.manager.status[other.id] == .connected(mountPoint: volume("/Volumes/Media")))
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Media/Music/x.mp3"))?.share.id == other.id)
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Media/Movies/2024"))?.share.id == share.id)

        // Dropped while connected and the server answers: ejected elsewhere, for both.
        await h.volumes.set([])
        await h.manager.volumesChanged()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
    }

    @Test func recheckReclassifiesOneShare() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: share.url)])
        await h.refresh()

        await h.prober.set("nas", reachable: false)
        let gate = MountGate()
        await h.prober.setGate(gate)
        h.manager.recheck(share.id)
        h.manager.recheck(share.id)  // coalesced
        #expect(await eventually { await h.prober.probeCount == 2 })
        await gate.release()
        await h.manager.waitForRechecks()
        #expect(h.manager.status[share.id] == .unreachable)
        #expect(await h.prober.probeCount == 2)
    }

    @Test func recheckDuringEjectDoesNotRemount() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A")
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: share.url)])
        await h.refresh()
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))
        #expect(await h.prober.probeCount == 1)

        // Ejected in Finder: the volume notification and a window's placeholder recheck race.
        await h.volumes.set([])
        let volumeGate = MountGate(), recheckGate = MountGate()
        await h.prober.setCallGates([volumeGate, recheckGate])
        let manager = h.manager
        let rematch = Task { await manager.volumesChanged() }
        #expect(await eventually { await h.prober.probeCount == 2 })
        h.manager.recheck(share.id)
        #expect(await eventually { await h.prober.probeCount == 3 })

        // The recheck finishes first.
        await recheckGate.release()
        await h.manager.waitForRechecks()
        await h.manager.waitForPendingAttempts()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        #expect(await h.mounter.mounts.isEmpty)

        await volumeGate.release()
        await rematch.value
        await h.manager.waitForPendingAttempts()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        #expect(await h.mounter.mounts.isEmpty)

        // Still eligible again after a network change.
        await h.manager.networkChanged()
        await h.manager.waitForPendingAttempts()
        #expect(await h.mounter.mounts.count == 1)
    }

    @Test func addressEditDoesNotOfferTheOldVolume() async throws {
        let h = try Harness()
        var share = try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: share.url)])
        await h.refresh()

        let old = share.url
        share.url = try url("smb://nas/B")
        h.store.update(share)
        h.manager.addressChanged(from: old)
        await h.manager.requestRefresh().value
        #expect(h.manager.rememberPrompts.isEmpty)
    }

    @Test func removeKeepsKeychain() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Keep", username: "bob", lastAuth: .password)
        await h.credentials.store("pw", for: share.url, username: "bob")
        await h.prober.set("nas", reachable: true)
        await h.refresh()
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/Keep")))

        await h.manager.remove(share.id)

        #expect(h.store.shares.isEmpty)
        #expect(h.manager.status[share.id] == nil)
        #expect(await h.credentials.itemCount == 1)
        #expect(await h.credentials.deletes == 0)
        #expect(await h.mounter.unmounts.isEmpty)
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Keep/a")) == nil)
        // Still mounted, but the user just removed it: not offered as "Remember this share?" this session.
        await h.manager.volumesChanged()
        await h.refresh()
        #expect(h.manager.rememberPrompts.isEmpty)
    }

    @Test func mountedButServerGoneIsUnreachableAndForceUnmounts() async throws {
        let h = try Harness()
        let gone = try h.share("smb://far/Gone", autoReconnect: false)
        let here = try h.share("smb://nas/Here", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([
            MountedShare(mountPoint: volume("/Volumes/Gone"), url: gone.url),
            MountedShare(mountPoint: volume("/Volumes/Here"), url: here.url),
        ])

        await h.refresh()
        #expect(h.manager.status[gone.id] == .unreachable)
        #expect(h.manager.status[here.id] == .connected(mountPoint: volume("/Volumes/Here")))
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Gone/x"))?.share.id == gone.id)

        try await h.manager.disconnect(gone.id)
        try await h.manager.disconnect(here.id)
        let unmounts = await h.mounter.unmounts
        #expect(unmounts.map(\.mountPoint) == [volume("/Volumes/Gone"), volume("/Volumes/Here")])
        #expect(unmounts.map(\.force) == [true, false])
        #expect(h.manager.status[gone.id] == .unreachable)
        #expect(h.manager.status[here.id] == .available(needsSignIn: false))

        // Unmounted: lookups fall back to the last mount path, so the UI can show "Disconnected".
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Gone/x"))?.share.id == gone.id)
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Here/y"))?.mountPoint == volume("/Volumes/Here"))

        // Not mounted any more: disconnecting again fails.
        await #expect(throws: MountError.self) { try await h.manager.disconnect(here.id) }
    }

    @Test func hasMountPointFollowsMountsAlsoWhileUnreachable() async throws {
        let h = try Harness()
        let gone = try h.share("smb://far/Gone", autoReconnect: false)
        let idle = try h.share("smb://far/Idle", autoReconnect: false)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/Gone"), url: gone.url)])

        await h.refresh()
        #expect(h.manager.status[gone.id] == .unreachable)
        #expect(h.manager.hasMountPoint(gone.id))
        #expect(!h.manager.hasMountPoint(idle.id))

        try await h.manager.disconnect(gone.id)
        #expect(!h.manager.hasMountPoint(gone.id))
    }

    @Test func userDisconnectIsNotUndoneByAutoReconnect() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A")
        await h.prober.set("nas", reachable: true)
        await h.refresh()
        #expect(await h.mounter.mounts.count == 1)
        try await h.manager.disconnect(share.id)
        await h.refresh()
        await h.manager.networkChanged()  // an in-app Disconnect holds for the whole session
        await h.manager.waitForPendingAttempts()
        #expect(await h.mounter.mounts.count == 1)
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        #expect(await h.manager.connect(share.id) == .connected(volume("/Volumes/A")))
    }

    @Test func ejectElsewhereWaitsForNetworkChange() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A")
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: share.url)])
        await h.refresh()
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))

        // Ejected in Finder while the server answers: treated as the user's choice.
        await h.volumes.set([])
        await h.manager.volumesChanged()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        await h.refresh()
        #expect(await h.mounter.mounts.isEmpty)

        // A network change (or wake) makes it eligible again.
        await h.manager.networkChanged()
        await h.manager.waitForPendingAttempts()
        #expect(await h.mounter.mounts.count == 1)
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))
    }

    @Test func stalePassDoesNotOverwriteNewerMountState() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.refresh()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))

        // A pass whose probe answer is stale: the server was "down" when probed...
        await h.prober.set("nas", reachable: false)
        let gate = MountGate()
        await h.prober.setGate(gate)
        let pass = Task { await h.manager.refreshAll() }
        #expect(await eventually { await h.prober.probeCount == 2 })
        // ...but meanwhile the share got mounted elsewhere.
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: share.url)])
        await h.manager.volumesChanged()
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))
        await gate.release()
        await pass.value
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))
    }

    @Test func staleVolumeListDoesNotOverwriteNewerState() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/A", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/A"), url: share.url)])
        await h.refresh()
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/A")))

        // volumesChanged gets a listing that still shows A mounted...
        let gate = MountGate()
        await h.volumes.setGate(gate)
        var notified = 0
        let token = NotificationCenter.default.addObserver(
            forName: ShareManager.didConnectNotification, object: h.manager, queue: nil
        ) { _ in MainActor.assumeIsolated { notified += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        let rematch = Task { await h.manager.volumesChanged() }
        #expect(await eventually { await h.volumes.listCount == 2 })
        // ...while the user disconnects it in the app.
        try await h.manager.disconnect(share.id)
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        await gate.release()
        await rematch.value
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
        #expect(notified == 0)
    }

    @Test func slowAutoReconnectDoesNotHoldRefreshes() async throws {
        let h = try Harness()
        let slow = try h.share("smb://nas/Slow")
        let other = try h.share("smb://far/Other", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.prober.set("far", reachable: true)
        let gate = MountGate()
        await h.mounter.setGate(gate)
        let manager = h.manager

        let first = Task { await manager.networkChanged() }
        #expect(await eventually { await h.mounter.mounts.count == 1 })
        #expect(await eventually { h.manager.status[other.id] == .available(needsSignIn: false) })

        await h.prober.set("far", reachable: false)
        let second = Task { await manager.networkChanged() }
        let secondPassDone = await eventually { h.manager.status[other.id] == .unreachable }
        await gate.release()
        #expect(secondPassDone)
        await first.value
        await second.value
        await h.manager.waitForPendingAttempts()
        #expect(await h.mounter.mounts.count == 1)
        #expect(h.manager.status[slow.id] == .connected(mountPoint: volume("/Volumes/Slow")))
    }

    @Test func otherFailureOnFirstConnectMarksAvailable() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Odd", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.mounter.setHandler { _, _ in .failure(.failed("boom")) }
        #expect(await h.manager.connect(share.id) == .failed("boom"))
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))

        let other = try h.share("smb://nas/Cancel", autoReconnect: false)
        await h.mounter.setHandler { _, _ in .failure(.cancelled) }
        guard case .failed = await h.manager.connectAsGuest(other.id) else {
            Issue.record("expected .failed")
            return
        }
        #expect(h.manager.status[other.id] == .available(needsSignIn: false))
    }

    @Test func externalMountClearsSignInFlag() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Locked")
        await h.prober.set("nas", reachable: true)
        await h.mounter.setHandler { _, _ in .failure(.authenticationFailed) }
        await h.refresh()
        #expect(h.manager.status[share.id] == .available(needsSignIn: true))

        // Mounted in Finder with the right password, then ejected there again.
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/Locked"), url: share.url)])
        await h.manager.volumesChanged()
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/Locked")))
        await h.volumes.set([])
        await h.manager.volumesChanged()
        #expect(h.manager.status[share.id] == .available(needsSignIn: false))
    }

    @Test func mountPointPrefersCurrentMounts() async throws {
        let h = try Harness()
        // B was last mounted at /Volumes/Data, which A now occupies, nested lookups included.
        var b = try h.share("smb://old/Data", autoReconnect: false)
        b.lastMountPath = "/Volumes/Data/inner"
        h.store.update(b)
        let a = try h.share("smb://nas/Data", autoReconnect: false)
        await h.prober.set("nas", reachable: true)
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/Data"), url: a.url)])
        await h.refresh()

        let hit = h.manager.mountPoint(containing: volume("/Volumes/Data/inner/file"))
        #expect(hit?.share.id == a.id)
        #expect(hit?.mountPoint == volume("/Volumes/Data"))
        #expect(h.manager.mountPoint(containing: volume("/Volumes/Other")) == nil)
    }

    @Test func credentialsDescriptionRedactsPassword() {
        let credentials = ShareCredentials(username: #"CORP\daniel"#, password: "hunter2")
        #expect(!String(describing: credentials).contains("hunter2"))
        #expect(!String(reflecting: credentials).contains("hunter2"))
        #expect(String(describing: credentials).contains("<redacted>"))
        #expect(!String(describing: ShareCredentials.automatic).contains("<redacted>"))
    }

    @Test func connectReportsUnreachableWithoutMounting() async throws {
        let h = try Harness()
        let share = try h.share("smb://far/X", autoReconnect: false)
        #expect(await h.manager.connect(share.id) == .unreachable)
        #expect(h.manager.status[share.id] == .unreachable)
        #expect(await h.mounter.mounts.isEmpty)
    }

    @Test func addAndConnectSavesAndMounts() async throws {
        let h = try Harness()
        await h.prober.set("nas", reachable: true)
        let (share, outcome) = await h.manager.addAndConnect(try url("smb://nas/New"))
        #expect(outcome == .connected(volume("/Volumes/New")))
        #expect(h.store.shares.map(\.id) == [share.id])
        #expect(share.lastMountPath == "/Volumes/New")
        #expect(h.manager.status[share.id] == .connected(mountPoint: volume("/Volumes/New")))
    }

    @Test func addAndConnectKeepsTypedUsername() async throws {
        let h = try Harness()
        await h.prober.set("nas", reachable: true)
        let (share, _) = await h.manager.addAndConnect(try url("smb://nas/New"), username: "bob")
        #expect(share.username == "bob")
    }

    @Test func postsDidConnectNotification() async throws {
        let h = try Harness()
        let share = try h.share("smb://nas/Note")
        await h.prober.set("nas", reachable: true)

        final class Box: @unchecked Sendable { var infos: [[AnyHashable: Any]] = [] }
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: ShareManager.didConnectNotification, object: nil, queue: nil
        ) { note in
            guard let info = note.userInfo, info["shareID"] as? UUID == share.id else { return }
            box.infos.append(info)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await h.refresh()  // auto-reconnect
        #expect(box.infos.count == 1)
        #expect(box.infos.first?["mountPoint"] as? URL == volume("/Volumes/Note"))
        await h.refresh()  // still connected: no repeat
        #expect(box.infos.count == 1)

        try await h.mounter.unmount(volume("/Volumes/Note"), force: false)
        await h.manager.volumesChanged()
        await h.volumes.set([MountedShare(mountPoint: volume("/Volumes/Note 1"), url: share.url)])
        await h.manager.volumesChanged()  // mounted elsewhere: discovered
        #expect(box.infos.count == 2)
        #expect(box.infos.last?["mountPoint"] as? URL == volume("/Volumes/Note 1"))
    }
}
