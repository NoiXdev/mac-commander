import Foundation
import Synchronization
import Testing
@testable import MacCommanderCore

struct ProcessRunnerTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func capturesStdoutAndStatus() async throws {
        let result = try await ProcessRunner.run(url("/bin/echo"), ["hi"])
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hi\n")
        #expect(result.status == 0)
    }

    @Test func capturesStderrAndFailure() async throws {
        let result = try await ProcessRunner.run(url("/bin/sh"), ["-c", "echo oops >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stderr == "oops\n")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let result = try await ProcessRunner.run(
            url("/bin/sh"), ["-c", "head -c 5000000 /dev/zero; head -c 200000 /dev/zero >&2"])
        #expect(result.stdout.count == 5_000_000)
    }

    @Test func stdinIsEmpty() async throws {
        let result = try await ProcessRunner.run(url("/bin/cat"), [])
        #expect(result.stdout.isEmpty)
    }

    @Test func cancellationTerminates() async throws {
        let task = Task { try await ProcessRunner.run(url("/bin/sleep"), ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func cancellationKillsAProcessIgnoringSIGTERM() async throws {
        // `exec` keeps the ignored SIGTERM; only SIGKILL ends it.
        let task = Task { try await ProcessRunner.run(url("/bin/sh"), ["-c", "trap '' TERM; exec sleep 30"]) }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func streamsLinesSplitOnCRAndLF() async throws {
        let lines = Mutex<[String]>([])
        let output = try await ProcessRunner.run(
            url("/bin/sh"), ["-c", "printf 'a\\rb\\nc' ; printf 'x\\n' >&2"],
            onLine: { line in lines.withLock { $0.append(line) } })
        #expect(Set(lines.withLock { $0 }) == ["a", "b", "c", "x"])
        #expect(output.status == 0)
    }
}
