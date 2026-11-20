import Foundation
import Testing
@testable import MacCommanderCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class Stamps: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date] = []
    var all: [Date] { lock.withLock { dates } }
    func record() { lock.withLock { dates.append(Date()) } }
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

/// Runs `body` on a thread of its own and returns its result. Timed steps go here: on a small CI runner the
/// cooperative pool can stay busy for seconds, so a `Task.sleep` between steps may take far longer than asked,
/// while the watcher's own queue keeps time.
private func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}

@Suite struct DirectoryWatcherTests {
    @Test func firesOnFileCreation() async throws {
        let dir = try TemporaryDirectory()
        let counter = Counter()
        let watcher = try #require(DirectoryWatcher(url: dir.url, debounce: .milliseconds(50)) {
            counter.increment()
        })
        try dir.file("a.txt")
        #expect(await waitUntil(timeout: 10) { counter.count >= 1 })
        watcher.cancel()
    }

    @Test func debouncesBursts() async throws {
        let dir = try TemporaryDirectory()
        let stamps = Stamps()
        // The debounce is far longer than the 30 ms pauses; the maximum latency is out of reach.
        let watcher = try #require(DirectoryWatcher(
            url: dir.url, debounce: .seconds(1), maxLatency: .seconds(60)
        ) { stamps.record() })
        let url = dir.url
        let burstEnd = try await onOwnThread {
            for i in 0..<10 {
                try Data().write(to: url.appendingPathComponent("f\(i).txt"))
                usleep(30_000)
            }
            return Date()
        }
        #expect(await waitUntil(timeout: 10) { stamps.all.count >= 1 })
        try await Task.sleep(for: .milliseconds(1500))
        let all = stamps.all
        #expect(all.count == 1)
        #expect(all.first.map { $0 >= burstEnd.addingTimeInterval(-0.05) } == true)
        watcher.cancel()
    }

    @Test func firesDuringContinuousEvents() async throws {
        let dir = try TemporaryDirectory()
        let counter = Counter()
        let watcher = try #require(DirectoryWatcher(
            url: dir.url, debounce: .milliseconds(200), maxLatency: .seconds(1)
        ) { counter.increment() })
        for i in 0..<50 {
            try dir.file("f\(i).txt")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(counter.count >= 2)
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
        let watcher = try #require(DirectoryWatcher(
            url: dir.url, debounce: .seconds(2), maxLatency: .seconds(60)
        ) { counter.increment() })
        let url = dir.url
        try await onOwnThread {
            try Data().write(to: url.appendingPathComponent("a.txt"))
            usleep(100_000) // event delivered, debounce pending
            watcher.cancel()
        }
        try await Task.sleep(for: .milliseconds(2500))
        #expect(counter.count == 0)
    }

    @Test func nilForMissingPath() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(DirectoryWatcher(url: missing, onChange: {}) == nil)
    }
}
