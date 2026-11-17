import Foundation
import Observation

public enum ShareStatus: Equatable, Sendable {
    /// Only before the first check of a share has finished.
    case checking
    case connected(mountPoint: URL)
    /// The server answers; `needsSignIn` after every automatic method was rejected.
    case available(needsSignIn: Bool)
    /// The server doesn't answer (the share may still be mounted; Disconnect then force-unmounts).
    case unreachable
}

public enum ConnectOutcome: Equatable, Sendable {
    case connected(URL), needsSignIn, unreachable, failed(String)
}

/// The state machine behind the saved network shares: classifies each share as Connected, Available or
/// Unreachable, reconnects shares automatically, signs in, and notices shares mounted outside the app.
///
/// It talks to the system only through `ShareMounter`, `ReachabilityProber`, `MountedVolumeLister` and
/// `CredentialStore`, whose implementations do their own off-main work; nothing here blocks the main actor.
///
/// Rules:
/// - A share among the mounted volumes (by `ShareURL.matchesMount`: smb and afp mount the share root, so a saved
///   address with a sub-path matches the root's mount) is connected unless its server doesn't answer; then it is
///   unreachable and its mount point is kept so Disconnect can force-unmount it.
/// - A connect always probes the server first, whatever the cached status says, and adopts a mount that is
///   already there instead of mounting again.
/// - Credentials are tried in the order `lastAuth`, then `.automatic`. A stored password is only tried if the
///   credential store has one. If every method is rejected the share needs a sign-in, and auto-reconnect skips
///   it until `signIn`, `connectAsGuest` or an edit (`clearSignInFlag`).
/// - At most one mount attempt per share is in flight; later callers await the same attempt.
/// - While any share is unreachable, everything is re-checked every 60 s.
/// - A share disconnected in the app isn't auto-reconnected for the rest of the session unless the user
///   connects it; one ejected elsewhere (for example in Finder) waits for the next network change or wake.
/// - Auto-reconnect mounts run in the background; a refresh pass never waits for them.
@MainActor @Observable
public final class ShareManager {
    /// Posted on `NotificationCenter.default` whenever a share becomes connected, by any path.
    /// `userInfo["mountPoint"]` is the mount point (URL), `userInfo["shareID"]` the share's id (UUID).
    public static let didConnectNotification = Notification.Name("MacCommander.shareDidConnect")

    static let recheckInterval: Duration = .seconds(60)
    static let probeTimeout: Duration = .seconds(3)

    @ObservationIgnored private let store: ShareStore
    @ObservationIgnored private let mounter: any ShareMounter
    @ObservationIgnored private let prober: any ReachabilityProber
    @ObservationIgnored private let volumes: any MountedVolumeLister
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    public private(set) var status: [UUID: ShareStatus] = [:]
    /// Mounted shares that are neither saved nor declined, each offered at most once per app session.
    public private(set) var rememberPrompts: [MountedShare] = []

    /// Set when every method was rejected; blocks auto-reconnect.
    @ObservationIgnored private var needsSignIn: [UUID: Bool] = [:]
    @ObservationIgnored private var inFlight: [UUID: Task<ConnectOutcome, Never>] = [:]
    /// Latest known mount point per share, also while its server is unreachable. Observed, so that views using
    /// `hasMountPoint` update when it changes.
    private var mountPoints: [UUID: URL] = [:]
    /// The mounted volumes as of the latest listing.
    @ObservationIgnored private var lastMounted: [MountedShare] = []
    /// Shares disconnected in the app; not auto-reconnected for the rest of the session unless the user
    /// connects them again.
    @ObservationIgnored private var userDisconnected: Set<UUID> = []
    /// Connected shares that were unmounted outside the app (for example ejected in Finder) while their server
    /// answered; not auto-reconnected until the next network change (or wake), or until the user connects them.
    @ObservationIgnored private var ejectedElsewhere: Set<UUID> = []
    /// Bumped whenever something changes a share's state (connect, disconnect, a re-match of the mounts, a
    /// refresh pass), so a pass that started earlier doesn't overwrite newer state with older observations.
    @ObservationIgnored private var generation: [UUID: Int] = [:]
    /// External mounts already offered in this session (compared with `matches`).
    @ObservationIgnored private var prompted: [ShareURL] = []

    @ObservationIgnored private var started = false
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    /// Shares with a `recheck` running.
    @ObservationIgnored private var rechecking: Set<UUID> = []

    public init(
        store: ShareStore, mounter: any ShareMounter, prober: any ReachabilityProber,
        volumes: any MountedVolumeLister, credentials: any CredentialStore,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.mounter = mounter
        self.prober = prober
        self.volumes = volumes
        self.credentials = credentials
        self.sleep = sleep
    }

    var isTimerRunning: Bool { timerTask != nil }

    // MARK: Lifecycle

    /// Runs the first check and from then on keeps the 60 s timer running while any share is unreachable.
    public func start() {
        started = true
        requestRefresh()
    }

    /// Stops the timer; call before dropping the manager. `start()` resumes.
    public func stop() {
        started = false
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: Refresh

    /// Probes every share's server (concurrently, once per host and port), then lists the mounted volumes
    /// once, classifies each share and starts auto-reconnecting the available ones. It doesn't wait for those
    /// mounts: a slow one must not hold up the next pass; their results are applied when they finish.
    /// A share whose state changed while the pass was running is left alone.
    public func refreshAll() async {
        let shares = store.shares
        for share in shares where status[share.id] == nil {
            status[share.id] = .checking
        }
        let generations = generation

        let reachable = await probe(shares)
        let mounted = await volumes.mountedShares()

        lastMounted = mounted
        let ids = Set(store.shares.map(\.id))
        for id in Array(status.keys) where !ids.contains(id) { status[id] = nil }
        for share in store.shares {
            guard generation[share.id] == generations[share.id] else { continue }
            guard let isReachable = reachable[Self.probeKey(share)] else { continue }
            classify(share, mounted: mounted, reachable: isReachable)
        }
        updatePrompts(mounted)
        updateTimer()
        autoReconnect()
    }

    /// Network path change (also sent on wake): a refresh, coalesced so that at most one runs and one more is
    /// queued. Shares ejected outside the app become eligible for auto-reconnect again.
    public func networkChanged() async {
        ejectedElsewhere.removeAll()
        await requestRefresh().value
    }

    /// Waits until no mount attempt is in flight (tests).
    func waitForPendingAttempts() async {
        while let running = inFlight.values.first { _ = await running.value }
    }

    /// A volume was mounted or unmounted: re-match the mounts. Only a connected share whose volume is gone
    /// has its server probed (all such shares at once): if the server answers, the share was unmounted
    /// elsewhere (for example ejected in Finder), the user's choice; if not, the link dropped and the share is
    /// unreachable (the 60 s timer runs).
    public func volumesChanged() async {
        let generations = generation
        let mounted = await volumes.mountedShares()
        lastMounted = mounted
        var dropped: [SavedShare] = []
        for share in store.shares {
            guard generation[share.id] == generations[share.id], let current = status[share.id] else { continue }
            let match = mounted.first { $0.url.matchesMount(share.url) }
            let before = (status[share.id], mountPoints[share.id])
            switch (current, match) {
            case (.unreachable, let match?):
                // Server known to be gone: stays unreachable; remember where it is for Disconnect.
                mountPoints[share.id] = match.mountPoint
                edit(share.id) { $0.lastMountPath = match.mountPoint.path }
            case (_, let match?):
                markConnected(share.id, at: match.mountPoint)
            case (.connected, nil):
                dropped.append(share)
            case (_, nil):
                mountPoints[share.id] = nil
            }
            if before != (status[share.id], mountPoints[share.id]) { bump(share.id) }
        }
        if !dropped.isEmpty {
            let reachable = await probe(dropped)
            for share in dropped {
                guard generation[share.id] == generations[share.id], self.share(share.id) != nil,
                    case .connected? = status[share.id]
                else { continue }
                markVolumeGone(share.id, reachable: reachable[Self.probeKey(share)] == true)
            }
        }
        updatePrompts(lastMounted)
        updateTimer()
    }

    /// A window found the share's folder gone (`BrowserModel` shows Disconnected): probes the server and
    /// re-matches the mounts for this share only, so a stale "connected" status doesn't linger. Coalesced: at
    /// most one recheck per share runs, and none while a mount attempt for it is in flight (that settles it).
    /// An available share may be auto-reconnected afterwards, as after a refresh.
    public func recheck(_ id: UUID) {
        guard let share = share(id), inFlight[id] == nil, rechecking.insert(id).inserted else { return }
        Task {
            defer { self.rechecking.remove(id) }
            let generations = self.generation
            let reachable = await self.probe(share)
            let mounted = await self.volumes.mountedShares()
            guard let current = self.share(id), self.generation[id] == generations[id], self.inFlight[id] == nil
            else { return }
            self.lastMounted = mounted
            if case .connected? = self.status[id], !mounted.contains(where: { $0.url.matchesMount(current.url) }) {
                // Same rule as `volumesChanged` (both may run for one Finder eject; whichever finishes first
                // decides): a connected share whose volume is gone while the server answers was ejected.
                self.markVolumeGone(id, reachable: reachable)
            } else {
                self.classify(current, mounted: mounted, reachable: reachable)
            }
            self.updatePrompts(mounted)
            self.updateTimer()
            self.autoReconnect()
        }
    }

    /// A connected share's volume is gone. If its server answers, it was unmounted elsewhere (for example
    /// ejected in Finder): the user's choice, not a dropped link, so it isn't auto-reconnected until the next
    /// network change. Otherwise the link dropped: unreachable.
    private func markVolumeGone(_ id: UUID, reachable: Bool) {
        bump(id)
        mountPoints[id] = nil
        if reachable {
            ejectedElsewhere.insert(id)
            status[id] = .available(needsSignIn: needsSignIn[id] ?? false)
        } else {
            status[id] = .unreachable
        }
    }

    /// Waits until no recheck is running (tests).
    func waitForRechecks() async {
        while !rechecking.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// A refresh pass, coalesced with one already running: at most one runs and one more is queued.
    @discardableResult
    public func requestRefresh() -> Task<Void, Never> {
        refreshRequested = true
        if let refreshLoop { return refreshLoop }
        let loop = Task {
            while self.refreshRequested {
                self.refreshRequested = false
                await self.refreshAll()
            }
            self.refreshLoop = nil
        }
        refreshLoop = loop
        return loop
    }

    private static func probeKey(_ share: SavedShare) -> String {
        "\(share.url.host):\(share.url.probePort)"
    }

    /// Reachability by `probeKey`.
    private func probe(_ shares: [SavedShare]) async -> [String: Bool] {
        var targets: [String: (host: String, port: Int)] = [:]
        for share in shares {
            targets[Self.probeKey(share)] = (share.url.host, share.url.probePort)
        }
        let prober = prober
        let timeout = Self.probeTimeout
        return await withTaskGroup(of: (String, Bool).self) { group in
            for (key, target) in targets {
                group.addTask {
                    (key, await prober.isReachable(host: target.host, port: target.port, timeout: timeout))
                }
            }
            var result: [String: Bool] = [:]
            for await (key, isReachable) in group { result[key] = isReachable }
            return result
        }
    }

    private func probe(_ share: SavedShare) async -> Bool {
        await prober.isReachable(host: share.url.host, port: share.url.probePort, timeout: Self.probeTimeout)
    }

    private func classify(_ share: SavedShare, mounted: [MountedShare], reachable: Bool) {
        let before = (status[share.id], mountPoints[share.id])
        defer { if before != (status[share.id], mountPoints[share.id]) { bump(share.id) } }
        let match = mounted.first { $0.url.matchesMount(share.url) }
        mountPoints[share.id] = match?.mountPoint
        if let match { edit(share.id) { $0.lastMountPath = match.mountPoint.path } }
        if !reachable {
            status[share.id] = .unreachable
        } else if let match {
            markConnected(share.id, at: match.mountPoint)
        } else {
            status[share.id] = .available(needsSignIn: needsSignIn[share.id] ?? false)
        }
    }

    /// Starts (without waiting) a mount for every available auto-reconnect share.
    private func autoReconnect() {
        let candidates = store.shares.filter { share in
            share.autoReconnect && status[share.id] == .available(needsSignIn: false)
                && needsSignIn[share.id] != true && !userDisconnected.contains(share.id)
                && !ejectedElsewhere.contains(share.id)
        }
        for share in candidates {
            attempt(share.id) { manager, share in await manager.mountWithSavedMethods(share) }
        }
    }

    // MARK: Timer

    private func updateTimer() {
        let needed = started && store.shares.contains { status[$0.id] == .unreachable }
        if !needed {
            timerTask?.cancel()
            timerTask = nil
        } else if timerTask == nil {
            let sleep = sleep
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await sleep(Self.recheckInterval) } catch { return }
                    guard !Task.isCancelled, let manager = self else { return }
                    await manager.requestRefresh().value
                }
            }
        }
    }

    // MARK: Connecting

    /// User click (also Reconnect): always probes the server first, whatever the cached status says (a
    /// "connected" status may be stale), then adopts the share's volume if it is mounted already, and only
    /// otherwise mounts with the saved methods. The outcome's URL is the mount point.
    public func connect(_ id: UUID) async -> ConnectOutcome {
        userDisconnected.remove(id)
        ejectedElsewhere.remove(id)
        return await attempt(id) { manager, share in
            guard await manager.probe(share) else {
                manager.markUnreachable(share.id)
                return .unreachable
            }
            if let mountPoint = await manager.adoptExistingMount(share) { return .connected(mountPoint) }
            let outcome = await manager.mountWithSavedMethods(share)
            manager.settleAfterFailure(id, outcome)
            return outcome
        }.value
    }

    /// Tries the given credentials once. On success the username is stored, and with `remember` the password
    /// is saved and becomes the share's method.
    public func signIn(_ id: UUID, username: String, password: String, remember: Bool) async -> ConnectOutcome {
        userDisconnected.remove(id)
        ejectedElsewhere.remove(id)
        await waitForAttempt(id)
        let credentials = ShareCredentials(username: username, password: password)
        return await attempt(id) { manager, share in
            let outcome = await manager.mountOnce(share, with: credentials)
            if outcome == .needsSignIn { manager.markNeedsSignIn(id) }
            manager.settleAfterFailure(id, outcome)
            guard case .connected = outcome else { return outcome }
            var saved = false
            if remember {
                do {
                    try await manager.credentials.save(password: password, for: share.url, username: username)
                    saved = true
                } catch {}
            }
            manager.edit(id) {
                $0.username = username
                $0.lastAuth = saved ? .password : .automatic
            }
            return outcome
        }.value
    }

    public func connectAsGuest(_ id: UUID) async -> ConnectOutcome {
        userDisconnected.remove(id)
        ejectedElsewhere.remove(id)
        await waitForAttempt(id)
        return await attempt(id) { manager, share in
            let outcome = await manager.mountOnce(share, with: .asGuest)
            if outcome == .needsSignIn { manager.markNeedsSignIn(id) }
            manager.settleAfterFailure(id, outcome)
            if case .connected = outcome { manager.edit(id) { $0.lastAuth = .guest } }
            return outcome
        }.value
    }

    /// Unmounts the share (forced when its server is unreachable), then re-classifies it.
    public func disconnect(_ id: UUID) async throws(MountError) {
        guard let mountPoint = mountPoints[id] else {
            throw .failed(String(localized: "The share isn’t connected."))
        }
        let force = status[id] == .unreachable
        try await mounter.unmount(mountPoint, force: force)
        guard let share = share(id) else { return }
        userDisconnected.insert(id)
        mountPoints[id] = nil
        lastMounted.removeAll { $0.mountPoint == mountPoint }
        bump(id)
        if force {
            status[id] = .unreachable
        } else {
            status[id] = await probe(share) ? .available(needsSignIn: needsSignIn[id] ?? false) : .unreachable
        }
        updateTimer()
    }

    /// ⌘K: saves the share (or finds the saved one) and connects it. `username` (typed as `user@` in the
    /// address) is stored with the share.
    public func addAndConnect(_ url: ShareURL, username: String? = nil) async -> (SavedShare, ConnectOutcome) {
        let share = store.add(url, username: username)
        let outcome = await connect(share.id)
        return (self.share(share.id) ?? share, outcome)
    }

    /// Clears the needs-sign-in flag after the user edited the share, so auto-reconnect tries it again.
    public func clearSignInFlag(_ id: UUID) {
        needsSignIn[id] = nil
        if status[id] == .available(needsSignIn: true) {
            status[id] = .available(needsSignIn: false)
        }
    }

    /// After an edit changed the share's address: the volume of the old address (possibly still mounted) isn't
    /// offered as "Remember this share?" in this session.
    public func addressChanged(from oldURL: ShareURL) {
        guard !prompted.contains(where: { $0.matchesMount(oldURL) }) else { return }
        prompted.append(oldURL)
    }

    /// Runs `body` as the share's single in-flight attempt, or returns the attempt already running.
    @discardableResult
    private func attempt(
        _ id: UUID, _ body: @escaping @MainActor (ShareManager, SavedShare) async -> ConnectOutcome
    ) -> Task<ConnectOutcome, Never> {
        if let running = inFlight[id] { return running }
        let task = Task { () -> ConnectOutcome in
            defer { self.inFlight[id] = nil }
            guard let share = self.share(id) else {
                return .failed(String(localized: "The share no longer exists."))
            }
            return await body(self, share)
        }
        inFlight[id] = task
        return task
    }

    /// A user attempt that failed for another reason than credentials or reachability: the server answered,
    /// so a share that had no status yet is available.
    private func settleAfterFailure(_ id: UUID, _ outcome: ConnectOutcome) {
        guard case .failed = outcome, share(id) != nil else { return }
        switch status[id] {
        case nil, .checking?:
            bump(id)
            status[id] = .available(needsSignIn: needsSignIn[id] ?? false)
        default:
            break
        }
    }

    private func waitForAttempt(_ id: UUID) async {
        while let running = inFlight[id] { _ = await running.value }
    }

    /// `lastAuth` first, then `.automatic`. `.password` is skipped when nothing is stored for the username.
    private func mountWithSavedMethods(_ share: SavedShare) async -> ConnectOutcome {
        let methods: [AuthMethod] = share.lastAuth == .automatic ? [.automatic] : [share.lastAuth, .automatic]
        for method in methods {
            let credentials: ShareCredentials
            switch method {
            case .automatic:
                credentials = .automatic
            case .guest:
                credentials = .asGuest
            case .password:
                guard let username = share.username,
                    let password = await self.credentials.password(for: share.url, username: username)
                else { continue }
                credentials = ShareCredentials(username: username, password: password)
            }
            let outcome = await mountOnce(share, with: credentials)
            switch outcome {
            case .needsSignIn:
                continue
            case .connected:
                edit(share.id) { $0.lastAuth = method }
                return outcome
            case .unreachable, .failed:
                return outcome
            }
        }
        markNeedsSignIn(share.id)
        return .needsSignIn
    }

    /// One mount call; applies success and unreachability to the share's state. A rejection is only reported:
    /// the caller decides when it means the share needs a sign-in.
    private func mountOnce(_ share: SavedShare, with credentials: ShareCredentials) async -> ConnectOutcome {
        do {
            let mountPoint = try await mounter.mount(share.url, credentials: credentials)
            guard self.share(share.id) != nil else { return .connected(mountPoint) }
            bump(share.id)
            userDisconnected.remove(share.id)
            ejectedElsewhere.remove(share.id)
            lastMounted.removeAll { $0.mountPoint == mountPoint }
            lastMounted.append(MountedShare(mountPoint: mountPoint, url: share.url))
            markConnected(share.id, at: mountPoint)
            updateTimer()
            return .connected(mountPoint)
        } catch {
            switch error {
            case .authenticationFailed:
                return .needsSignIn
            case .unreachable:
                markUnreachable(share.id)
                return .unreachable
            case .cancelled:
                return .failed(String(localized: "The connection was cancelled."))
            case .alreadyMounted:
                // Mounted already (by Finder, or by us under another address): use that volume.
                if let mountPoint = await adoptExistingMount(share) { return .connected(mountPoint) }
                return .failed(String(localized: "Already connected."))
            case .failed(let message):
                return .failed(message)
            }
        }
    }

    /// Lists the mounted volumes; when one serves the share, the share is connected there (no mount call)
    /// and its mount point is returned.
    private func adoptExistingMount(_ share: SavedShare) async -> URL? {
        let mounted = await volumes.mountedShares()
        lastMounted = mounted
        guard self.share(share.id) != nil, let match = mounted.first(where: { $0.url.matchesMount(share.url) })
        else { return nil }
        bump(share.id)
        markConnected(share.id, at: match.mountPoint)
        updateTimer()
        return match.mountPoint
    }

    private func markNeedsSignIn(_ id: UUID) {
        guard share(id) != nil else { return }
        needsSignIn[id] = true
        bump(id)
        if case .connected = status[id] { return }
        status[id] = .available(needsSignIn: true)
    }

    private func markUnreachable(_ id: UUID) {
        guard share(id) != nil else { return }
        bump(id)
        status[id] = .unreachable
        updateTimer()
    }

    /// Also clears the needs-sign-in flag: however it got mounted, the share evidently doesn't need one.
    private func markConnected(_ id: UUID, at mountPoint: URL) {
        needsSignIn[id] = nil
        let previous = status[id]
        status[id] = .connected(mountPoint: mountPoint)
        mountPoints[id] = mountPoint
        edit(id) { $0.lastMountPath = mountPoint.path }
        if previous != .connected(mountPoint: mountPoint) {
            NotificationCenter.default.post(
                name: Self.didConnectNotification, object: self,
                userInfo: ["mountPoint": mountPoint, "shareID": id])
        }
    }

    // MARK: External mounts

    /// "Remember": saves the mounted share; it is connected right away if it is still mounted.
    public func remember(_ mounted: MountedShare) {
        rememberPrompts.removeAll { $0.url.matches(mounted.url) }
        let share = store.add(mounted.url, username: nil)
        if let current = lastMounted.first(where: { $0.url.matches(mounted.url) }) {
            markConnected(share.id, at: current.mountPoint)
        }
    }

    /// "Not Now": never offered again (persisted).
    public func decline(_ mounted: MountedShare) {
        rememberPrompts.removeAll { $0.url.matches(mounted.url) }
        store.decline(mounted.url)
    }

    /// Offers mounted volumes that serve no saved share (`matchesMount`), weren't declined and weren't offered
    /// (or removed, or re-addressed) in this session.
    private func updatePrompts(_ mounted: [MountedShare]) {
        for share in mounted {
            guard !store.shares.contains(where: { $0.url.matchesMount(share.url) }), !store.isDeclined(share.url),
                !prompted.contains(where: { $0.matchesMount(share.url) })
            else { continue }
            prompted.append(share.url)
            rememberPrompts.append(share)
        }
    }

    // MARK: Removing and lookups

    /// Removes the share from the sidebar. It stays mounted, and its Keychain item is kept (the user may still
    /// use it in Finder). It isn't offered as "Remember this share?" again in this session.
    public func remove(_ id: UUID) async {
        if let share = share(id), !prompted.contains(where: { $0.matchesMount(share.url) }) {
            prompted.append(share.url)
        }
        store.remove(id)
        status[id] = nil
        needsSignIn[id] = nil
        mountPoints[id] = nil
        inFlight[id] = nil
        userDisconnected.remove(id)
        ejectedElsewhere.remove(id)
        generation[id] = nil
        updateTimer()
    }

    /// The saved share whose mount point contains `url`. Current mount points are checked first; only if none
    /// contains `url` are the last mount points of shares that aren't mounted now. Compares standardized paths
    /// only (no file-system access); within each group the longest mount point wins. Several saved addresses
    /// inside one smb/afp share use the same mount point; then the one whose folder (`subpathInShare`) contains
    /// `url` most closely wins.
    public func mountPoint(containing url: URL) -> (share: SavedShare, mountPoint: URL)? {
        let path = url.standardizedFileURL.path
        func contains(_ root: String) -> Bool {
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        func longest(_ candidates: [(SavedShare, URL)]) -> (share: SavedShare, mountPoint: URL)? {
            var best: (share: SavedShare, mountPoint: URL, length: Int, folderLength: Int)?
            for (share, candidate) in candidates {
                let root = candidate.standardizedFileURL.path
                guard contains(root) else { continue }
                let folder = share.url.folder(atMountPoint: candidate).standardizedFileURL.path
                let folderLength = contains(folder) ? folder.count : 0
                if let best, (root.count, folderLength) <= (best.length, best.folderLength) { continue }
                best = (share, candidate, root.count, folderLength)
            }
            return best.map { ($0.share, $0.mountPoint) }
        }
        let shares = store.shares
        let current = shares.compactMap { share in mountPoints[share.id].map { (share, $0) } }
        if let hit = longest(current) { return hit }
        let previous = shares.compactMap { share -> (SavedShare, URL)? in
            guard mountPoints[share.id] == nil, let last = share.lastMountPath else { return nil }
            return (share, URL(fileURLWithPath: last))
        }
        return longest(previous)
    }

    /// Whether the share is mounted as far as the manager knows, also while its server is unreachable (then
    /// Disconnect force-unmounts it).
    public func hasMountPoint(_ id: UUID) -> Bool {
        mountPoints[id] != nil
    }

    // MARK: Helpers

    private func share(_ id: UUID) -> SavedShare? {
        store.shares.first { $0.id == id }
    }

    /// Applies `change` to the stored share; writes only if something changed.
    private func edit(_ id: UUID, _ change: (inout SavedShare) -> Void) {
        guard var share = share(id) else { return }
        let before = share
        change(&share)
        if share != before { store.update(share) }
    }

    private func bump(_ id: UUID) {
        generation[id, default: 0] += 1
    }
}
