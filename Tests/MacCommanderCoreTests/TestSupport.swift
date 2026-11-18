import Foundation

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
