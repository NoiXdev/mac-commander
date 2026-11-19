import Foundation
import Synchronization

/// Finds a working Homebrew ffmpeg for the Convert menu. ffmpeg is never bundled. The result is cached
/// and re-checked once it is older than `cacheLifetime`.
public actor FFmpegLocator {
    public static let shared = FFmpegLocator(
        candidates: [URL(filePath: "/opt/homebrew/bin/ffmpeg"), URL(filePath: "/usr/local/bin/ffmpeg")],
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) },
        versionCheck: { url in
            // Race `ffmpeg -version` against a 5 s timeout; cancelling the loser terminates the process.
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    guard let output = try? await ProcessRunner.run(url, ["-version"]) else { return false }
                    return output.status == 0
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        })

    private static let cacheLifetime: TimeInterval = 60

    private let candidates: [URL]
    private let isExecutable: @Sendable (URL) -> Bool
    private let versionCheck: @Sendable (URL) async -> Bool
    private let now: @Sendable () -> Date
    private var checkedAt: Date?
    private let cache = Mutex<FFmpegStatus?>(nil)

    public init(
        candidates: [URL], isExecutable: @escaping @Sendable (URL) -> Bool,
        versionCheck: @escaping @Sendable (URL) async -> Bool, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.candidates = candidates
        self.isExecutable = isExecutable
        self.versionCheck = versionCheck
        self.now = now
    }

    /// Last known result without checking (nil before the first check) — for building menus synchronously.
    public nonisolated var cachedStatus: FFmpegStatus? { cache.withLock { $0 } }

    /// Cached result; re-checks when older than 60 s (or never checked). The first candidate that is
    /// executable decides: version check passes → .available(url), fails → .broken; none executable → .missing.
    public func status() async -> FFmpegStatus {
        if let checkedAt, let cached = cachedStatus, now().timeIntervalSince(checkedAt) < Self.cacheLifetime {
            return cached
        }
        let result: FFmpegStatus
        if let url = candidates.first(where: isExecutable) {
            result = await versionCheck(url) ? .available(url) : .broken
        } else {
            result = .missing
        }
        checkedAt = now()
        cache.withLock { $0 = result }
        return result
    }
}
