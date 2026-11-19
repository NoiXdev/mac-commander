import Foundation
import Synchronization

/// What a finished child process produced.
public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
}

/// Runs child processes without blocking the calling thread.
public enum ProcessRunner {
    /// How long a cancelled child gets to exit after SIGTERM before it is sent SIGKILL.
    static let killDelay: DispatchTimeInterval = .seconds(1)

    /// The running process, shared with the cancellation handler. `terminate()` is only valid after launch.
    private final class Run: @unchecked Sendable {
        let process = Process()
        /// launched, cancelled; guarded so a cancel never races the launch.
        let state = Mutex<(launched: Bool, cancelled: Bool)>((false, false))
        let outputData = Mutex(Data())
        let errorData = Mutex(Data())
    }

    /// Reads `handle` to EOF, collecting everything and reporting each line to `onLine`. Lines end at
    /// "\n" or "\r" (progress output redraws with "\r"); empty lines are skipped, a trailing partial line
    /// is flushed at EOF.
    private static func drain(_ handle: FileHandle, onLine: (@Sendable (String) -> Void)?) -> Data {
        guard let onLine else { return handle.readDataToEndOfFile() }
        var all = Data()
        var pending = Data()
        func emit(_ bytes: Data) {
            if !bytes.isEmpty { onLine(String(decoding: bytes, as: UTF8.self)) }
        }
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            all.append(chunk)
            pending.append(chunk)
            while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                emit(pending[pending.startIndex..<index])
                pending = Data(pending[(index + 1)...])
            }
        }
        emit(pending)
        return all
    }

    /// Runs `executable` with stdin = /dev/null. Drains stdout and stderr concurrently (no pipe deadlock),
    /// and returns once the process has exited and both pipes have reached EOF. Task cancellation
    /// terminates the process (SIGTERM, SIGKILL after `killDelay`) and throws `CancellationError`. A launch
    /// failure is rethrown as is; a non-zero exit is not an error here, the caller inspects `status`. `onLine`
    /// (optional) receives every stdout and stderr line as it arrives, possibly from a background thread.
    @concurrent public static func run(
        _ executable: URL, _ arguments: [String], currentDirectory: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let run = Run()
        let process = run.process
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                // Resume once the process has exited and both pipes are drained (a full pipe would
                // otherwise stall the child).
                let group = DispatchGroup()
                group.enter()
                group.enter()
                group.enter()
                process.terminationHandler = { _ in group.leave() }
                let launchError: (any Error)? = run.state.withLock { state in
                    if state.cancelled { return CancellationError() }
                    do {
                        try process.run()
                        state.launched = true
                        return nil
                    } catch {
                        return error
                    }
                }
                if let launchError {
                    process.terminationHandler = nil
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: launchError)
                    return
                }
                // The parent's copies of the write ends must close, or the reads below never see EOF.
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
                DispatchQueue.global(qos: .utility).async {
                    let data = drain(outputPipe.fileHandleForReading, onLine: onLine)
                    run.outputData.withLock { $0 = data }
                    group.leave()
                }
                DispatchQueue.global(qos: .utility).async {
                    let data = drain(errorPipe.fileHandleForReading, onLine: onLine)
                    run.errorData.withLock { $0 = data }
                    group.leave()
                }
                group.notify(queue: .global(qos: .utility)) {
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        } onCancel: {
            run.state.withLock { state in
                state.cancelled = true
                guard state.launched else { return }
                run.process.terminate()
                // A child that ignores SIGTERM would keep the call (and its caller) waiting forever.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killDelay) {
                    if run.process.isRunning { kill(run.process.processIdentifier, SIGKILL) }
                }
            }
        }

        if run.state.withLock({ $0.cancelled }) { throw CancellationError() }
        return ProcessOutput(
            status: status,
            stdout: run.outputData.withLock { $0 },
            stderr: String(decoding: run.errorData.withLock { $0 }, as: UTF8.self))
    }
}
