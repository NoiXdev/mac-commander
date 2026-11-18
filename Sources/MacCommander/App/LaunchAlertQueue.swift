import Foundation

/// Runs launch-time alerts strictly one after another, so two alerts are never up at once. Each entry returns
/// when its alert was dismissed.
@MainActor
final class LaunchAlertQueue {
    static let shared = LaunchAlertQueue()

    private var pending: [@MainActor () async -> Void] = []
    private var isDraining = false

    func enqueue(_ present: @escaping @MainActor () async -> Void) {
        pending.append(present)
        guard !isDraining else { return }
        isDraining = true
        // In a task, so the first alert doesn't hold up whatever is enqueueing it (the first window).
        Task {
            while !pending.isEmpty {
                await pending.removeFirst()()
            }
            isDraining = false
        }
    }
}
