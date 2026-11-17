import Foundation
import Testing
@testable import MacCommanderCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// Polls until `condition` holds or the deadline passes.
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite struct DirectoryWatcherTests {
    @Test func firesOnFileCreation() async throws {
        let dir = try TemporaryDirectory()
        let counter = Counter()
        let watcher = try #require(DirectoryWatcher(url: dir.url, debounce: .milliseconds(50)) {
            counter.increment()
        })
        try dir.file("a.txt")
        #expect(await waitUntil(timeout: 2) { counter.count >= 1 })
        watcher.cancel()
    }

    @Test func debouncesBursts() async throws {
        let dir = try TemporaryDirectory()
        let counter = Counter()
        let watcher = try #require(DirectoryWatcher(url: dir.url, debounce: .milliseconds(200)) {
            counter.increment()
        })
        for i in 0..<20 { try dir.file("f\(i).txt") }
        #expect(await waitUntil(timeout: 1) { counter.count >= 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(counter.count >= 1)
        #expect(counter.count < 5)
        watcher.cancel()
    }

    @Test func noCallbackAfterCancel() async throws {
        let dir = try TemporaryDirectory()
        let counter = Counter()
        let watcher = try #require(DirectoryWatcher(url: dir.url, debounce: .milliseconds(50)) {
            counter.increment()
        })
        watcher.cancel()
        watcher.cancel() // idempotent
        try dir.file("a.txt")
        try await Task.sleep(for: .milliseconds(400))
        #expect(counter.count == 0)
    }

    @Test func cancelDuringPendingDebounceSuppressesCallback() async throws {
        let dir = try TemporaryDirectory()
        let counter = Counter()
        let watcher = try #require(DirectoryWatcher(url: dir.url, debounce: .milliseconds(300)) {
            counter.increment()
        })
        try dir.file("a.txt")
        try await Task.sleep(for: .milliseconds(100)) // event delivered, debounce pending
        watcher.cancel()
        try await Task.sleep(for: .milliseconds(500))
        #expect(counter.count == 0)
    }

    @Test func nilForMissingPath() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(DirectoryWatcher(url: missing, onChange: {}) == nil)
    }
}
