import Foundation

/// CPU time the calling thread spends in `body`. Unlike wall-clock time it doesn't grow while a busy CI runner keeps
/// the thread waiting for a core, so a speed limit on single-threaded work holds on a small machine too.
func threadCPUTime<T>(_ body: () throws -> T) rethrows -> (result: T, time: Duration) {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    let result = try body()
    let time = Duration.nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start))
    return (result, time)
}

final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCommanderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String, contents: String = "") throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    @discardableResult
    func folder(_ name: String) throws -> URL {
        let folderURL = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Hands out `UserDefaults` suites with fresh UUID names and removes them all on deinit. Held by a test
/// suite instance, which Swift Testing creates per test, so the suites go away after each test.
final class TemporaryDefaults: @unchecked Sendable {
    // @unchecked: `names` is only touched under `lock`.
    private let lock = NSLock()
    private var names: [String] = []

    func make() -> UserDefaults {
        let name = UUID().uuidString
        lock.withLock { names.append(name) }
        return UserDefaults(suiteName: name)!
    }

    deinit {
        for name in names { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    }
}
