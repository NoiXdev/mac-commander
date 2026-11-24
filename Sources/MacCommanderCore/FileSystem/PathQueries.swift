import AppKit
import Foundation

/// What one look at a path found. Symlinks are followed (a symlink to a folder is a folder).
public struct PathInfo: Sendable, Equatable {
    public let exists: Bool
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isRegularFile: Bool
    /// False for network volumes. A missing path reports true: there is no volume to ask, and
    /// the caller treats it as gone anyway.
    public let isLocalVolume: Bool
    /// A folder a double-click navigates into: a directory that isn't a package.
    public var isPlainFolder: Bool { isDirectory && !isPackage }

    public init(exists: Bool, isDirectory: Bool, isPackage: Bool, isRegularFile: Bool, isLocalVolume: Bool) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isRegularFile = isRegularFile
        self.isLocalVolume = isLocalVolume
    }

    public static let missing = PathInfo(
        exists: false, isDirectory: false, isPackage: false, isRegularFile: false, isLocalVolume: true)
}

/// File-system questions the UI and the browser model ask about single paths, always answered off the
/// main actor: any path may be on a network volume, where a `stat` can block for as long as the server
/// takes to time out. None of these time out themselves; a hung call only holds a background thread.
///
/// The blocking work runs on GCD, never on Swift's cooperative pool: that pool has about one thread per core
/// and doesn't grow when threads block, so a few hung `stat`s there would stall every task in the app. Each
/// call gets its own serial queue: those are "overcommit" queues, which get a thread at once even when every
/// core is busy (a shared concurrent queue is limited to about one running thread per core, so a quick `stat`
/// would wait behind CPU-heavy listings). `info` calls for the same path share one in-flight lookup, so
/// repeated clicks or focus changes don't pile up threads on a dead server.
public enum PathQueries {
    /// A queue for one blocking call (see the type's documentation). Queues are cheap; idle threads are reused.
    private static func queue() -> DispatchQueue {
        DispatchQueue(label: "dev.noix.MacCommander.PathQueries", qos: .userInitiated)
    }

    /// Runs `work` on the blocking-I/O queue and returns its result. For any call that may touch a network
    /// volume (`stat`, `resourceValues`, `icon(forFile:)`, `open`, listings).
    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue().async { continuation.resume(returning: work()) }
        }
    }

    /// The throwing variant of `run`.
    public static func run<T: Sendable, E: Error>(_ work: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
        let result: Result<T, E> = await run {
            do throws(E) { return .success(try work()) } catch { return .failure(error) }
        }
        return try result.get()
    }

    /// One `stat` (plus a `resourceValues` call for package and volume flags when the path exists).
    /// Concurrent calls for the same standardized path share one lookup.
    public static func info(_ url: URL) async -> PathInfo {
        let key = url.standardizedFileURL.path
        return await withCheckedContinuation { continuation in
            guard inFlight.join(key, continuation) else { return }
            queue().async {
                testDelay(for: key)
                inFlight.finish(key, with: infoNow(url))
            }
        }
    }

    /// Opens `url` with its default app, like `NSWorkspace.open`, without blocking the caller: LaunchServices
    /// reads the item (its type, a package's bundle) before opening it, which can block on a network volume, so
    /// the call is made on the blocking-I/O queue. Returns at once. Failures aren't reported to the caller, as
    /// before; LaunchServices still asks the user when no app can open the item.
    public nonisolated static func openWithDefaultApp(_ url: URL) {
        Task.detached { _ = await open([url], withApplicationAt: nil) }
    }

    /// Opens `urls` with the app at `app`, or each with its default app when `app` is nil, off the main
    /// actor (see `openWithDefaultApp`). Returns the error for the caller to show.
    @discardableResult
    public nonisolated static func open(_ urls: [URL], withApplicationAt app: URL?) async -> (any Error)? {
        let result: Result<Void, any Error> = await withCheckedContinuation { continuation in
            queue().async {
                let configuration = NSWorkspace.OpenConfiguration()
                let completion: @Sendable ((any Error)?) -> Void = { error in
                    continuation.resume(returning: error.map { .failure($0) } ?? .success(()))
                }
                if let app {
                    NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration, completionHandler: { _, error in completion(error) })
                } else {
                    let group = DispatchGroup()
                    let firstError = FirstError()
                    for url in urls {
                        group.enter()
                        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                            if let error { firstError.set(error) }
                            group.leave()
                        }
                    }
                    group.notify(queue: .global()) { completion(firstError.value) }
                }
            }
        }
        if case .failure(let error) = result { return error }
        return nil
    }

    /// Opens `urls` honoring `rules`: files whose rule app is located open with it (`open(_:withApplicationAt:)`),
    /// the rest with their default app. The groups are resolved on the blocking-I/O queue. Returns the first
    /// error from a rule-app group; default-app errors are dropped, as `openWithDefaultApp` does.
    @discardableResult
    public nonisolated static func open(
        _ urls: [URL], rules: OpenWithRules, locator: some ApplicationLocating = WorkspaceApplicationLocator()
    ) async -> (any Error)? {
        await open(urls, rules: rules, locator: locator, opening: { app, urls in
            await open(urls, withApplicationAt: app)
        })
    }

    /// Test seam for `open(_:rules:locator:)`: `opening` opens one group (`nil` app: each file's default app)
    /// and returns its error. Groups open concurrently.
    nonisolated static func open(
        _ urls: [URL], rules: OpenWithRules, locator: some ApplicationLocating,
        opening: @escaping @Sendable (URL?, [URL]) async -> (any Error)?
    ) async -> (any Error)? {
        let groups = await run { rules.groups(for: urls, locator: locator) }
        let errors = await withTaskGroup(of: (Int, (any Error)?).self) { tasks in
            for (index, group) in groups.enumerated() {
                tasks.addTask { (index, await opening(group.app, group.urls)) }
            }
            var errors: [Int: any Error] = [:]
            for await (index, error) in tasks { errors[index] = error }
            return errors
        }
        return groups.indices.lazy
            .filter { groups[$0].app != nil }
            .compactMap { errors[$0] }
            .first
    }

    /// Asks iCloud to download `url`. Errors are ignored: the file then opens as it is, and the system
    /// reports a failed download itself.
    public static func startDownloading(_ url: URL) async {
        await run { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
    }

    /// `ArchivePath.split` off the main actor.
    public static func archiveLocation(_ url: URL) async -> ArchiveLocation? {
        await run { ArchivePath.split(url) }
    }

    /// `PathUtilities.nearestExistingAncestor` off the main actor.
    public static func nearestExistingFolder(_ url: URL) async -> URL {
        await run { PathUtilities.nearestExistingAncestor(of: url) }
    }

    /// The path with every symlink resolved (`realpath`, so `/var/x` gives `/private/var/x`), for comparing
    /// two spellings of one folder. A path that can't be resolved comes back standardized.
    public static func canonicalPath(_ url: URL) async -> String {
        await run { canonicalPathNow(url) }
    }

    /// The synchronous body of `canonicalPath`, for callers already on the queue.
    public static func canonicalPathNow(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `url` with its symlinks resolved when the item itself is a symlink; otherwise `url` as given.
    public static func resolvingSymlink(_ url: URL) async -> URL {
        await run {
            let isSymlink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            return isSymlink ? url.resolvingSymlinksInPath() : url
        }
    }

    /// Whether anything is at `url`, without following a final symlink (a broken symlink exists).
    public static func entryExists(_ url: URL) async -> Bool {
        await run {
            var info = stat()
            return lstat(url.path, &info) == 0
        }
    }

    /// The name Finder shows (localized, e.g. "Schreibtisch" for `~/Desktop`); the last path component when
    /// the item can't be asked.
    public static func displayName(_ url: URL) async -> String {
        await run {
            if let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName { return name }
            return url.path == "/" ? FileManager.default.displayName(atPath: "/") : url.lastPathComponent
        }
    }

    // MARK: - In-flight sharing

    private static let inFlight = InFlightLookups()

    /// Waiters per path for `info`.
    private final class InFlightLookups: @unchecked Sendable {
        // @unchecked: `waiters` is only touched while holding `lock`.
        private let lock = NSLock()
        private var waiters: [String: [CheckedContinuation<PathInfo, Never>]] = [:]

        /// Adds a waiter; true when it is the first one, which must start the lookup.
        func join(_ key: String, _ continuation: CheckedContinuation<PathInfo, Never>) -> Bool {
            lock.withLock {
                let isFirst = waiters[key] == nil
                waiters[key, default: []].append(continuation)
                return isFirst
            }
        }

        func finish(_ key: String, with info: PathInfo) {
            let resumed = lock.withLock { waiters.removeValue(forKey: key) ?? [] }
            for continuation in resumed { continuation.resume(returning: info) }
        }
    }

    // MARK: - Test hook

    nonisolated(unsafe) private static var delays: [String: TimeInterval] = [:]
    private static let delaysLock = NSLock()

    /// Test hook: `info` for paths under `prefix` sleeps `seconds` on its queue thread first, like a stat on an
    /// unresponsive server. nil removes the delay.
    static func setTestDelay(_ seconds: TimeInterval?, forPathsUnder prefix: String) {
        delaysLock.withLock {
            delays[prefix] = seconds
            if seconds == nil { delayedLookups[prefix] = nil }
        }
    }

    nonisolated(unsafe) private static var delayedLookups: [String: Int] = [:]

    /// Test hook: how many `info` lookups (after sharing) ran for paths under a delayed `prefix`.
    static func testLookupCount(forPathsUnder prefix: String) -> Int {
        delaysLock.withLock { delayedLookups[prefix] ?? 0 }
    }

    private static func testDelay(for path: String) {
        let delay: TimeInterval? = delaysLock.withLock {
            guard let match = delays.first(where: { path.hasPrefix($0.key) }) else { return nil }
            delayedLookups[match.key, default: 0] += 1
            return match.value
        }
        if let delay { Thread.sleep(forTimeInterval: delay) }
    }

    /// The synchronous body of `info`, for callers already off the main actor.
    public static func infoNow(_ url: URL) -> PathInfo {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return .missing }
        let type = info.st_mode & S_IFMT
        let isDirectory = type == S_IFDIR
        // Package and volume flags describe the target, so resolve a symlink first (lstat is cheap
        // next to the stat above, which already reached the target).
        var link = stat()
        let target = lstat(url.path, &link) == 0 && link.st_mode & S_IFMT == S_IFLNK
            ? url.resolvingSymlinksInPath() : url
        let values = try? target.resourceValues(forKeys: [.isPackageKey, .volumeIsLocalKey])
        return PathInfo(
            exists: true,
            isDirectory: isDirectory,
            isPackage: isDirectory && values?.isPackage == true,
            isRegularFile: type == S_IFREG,
            isLocalVolume: values?.volumeIsLocal ?? true)
    }
}

/// The path queries `BrowserModel` uses; a test hook so tests can slow them down. The default forwards to
/// `PathQueries`. Implementations must not run on the caller's actor.
protocol PathQueriesProvider: Sendable {
    func info(_ url: URL) async -> PathInfo
    func archiveLocation(_ url: URL) async -> ArchiveLocation?
    func nearestExistingFolder(_ url: URL) async -> URL
    func canonicalPath(_ url: URL) async -> String
    func resolvingSymlink(_ url: URL) async -> URL
    func entryExists(_ url: URL) async -> Bool
}

struct LivePathQueries: PathQueriesProvider {
    func info(_ url: URL) async -> PathInfo { await PathQueries.info(url) }
    func archiveLocation(_ url: URL) async -> ArchiveLocation? { await PathQueries.archiveLocation(url) }
    func nearestExistingFolder(_ url: URL) async -> URL { await PathQueries.nearestExistingFolder(url) }
    func canonicalPath(_ url: URL) async -> String { await PathQueries.canonicalPath(url) }
    func resolvingSymlink(_ url: URL) async -> URL { await PathQueries.resolvingSymlink(url) }
    func entryExists(_ url: URL) async -> Bool { await PathQueries.entryExists(url) }
}

/// The first error reported by several concurrent completions.
private final class FirstError: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?
    var value: (any Error)? { lock.withLock { stored } }
    func set(_ error: any Error) { lock.withLock { if stored == nil { stored = error } } }
}
