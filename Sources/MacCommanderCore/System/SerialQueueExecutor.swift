import Dispatch

/// A task executor that runs every job on one private serial `DispatchQueue`.
///
/// Long file operations (transfers, trash, compress, extract, folder sizes, undo) block on file-system
/// calls, and on a dead network share a call can block for minutes. Swift's cooperative pool has about one
/// thread per core and doesn't grow when threads block, so a few such operations there would stall every
/// task in the app. Serial queues are "overcommit" queues: GCD gives each one a thread at once, even when
/// every core is busy, so an operation running here blocks only its own thread. The same idea as
/// `PathQueries.run`, for whole async operations.
///
/// Use `withOwnThread`: under its preference, `body` and every nonisolated or `@concurrent` function it
/// calls run on the executor; actor-isolated code (the main actor) still runs on its actor.
public final class SerialQueueExecutor: TaskExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }

    /// Runs `body` with a new executor (labelled `label`) as the task's preferred executor, so the work
    /// gets its own thread. The executor lives as long as jobs are queued on it.
    public static func withOwnThread<T: Sendable>(
        label: String, _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await withTaskExecutorPreference(SerialQueueExecutor(label: label), operation: body)
    }
}
