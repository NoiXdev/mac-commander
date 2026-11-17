import MacCommanderCore
import SwiftUI

/// The running file operations, one row each, at the bottom of a browser window.
///
/// A row appears only after its operation has run for `delay`, so quick operations don't flicker.
struct OperationsStrip: View {
    @Environment(FileOperationCenter.self) private var center
    /// When each running operation was first seen; pruned as operations end.
    private let firstSeenState = State<[UUID: Date]>(initialValue: [:])
    /// Re-evaluated when a hidden row becomes due.
    private let nowState = State(initialValue: Date())
    private var firstSeen: [UUID: Date] {
        get { firstSeenState.wrappedValue }
        nonmutating set { firstSeenState.wrappedValue = newValue }
    }
    private var now: Date {
        get { nowState.wrappedValue }
        nonmutating set { nowState.wrappedValue = newValue }
    }

    static let delay: TimeInterval = 0.5

    var body: some View {
        let visible = center.operations.filter { operation in
            guard let seen = firstSeen[operation.id] else { return false }
            return now.timeIntervalSince(seen) >= Self.delay
        }
        VStack(spacing: 0) {
            // Keeps the stack (and its task) alive while no row is shown.
            Color.clear.frame(height: 0)
            if !visible.isEmpty {
                Divider()
                ForEach(visible) { operation in
                    OperationRow(operation: operation) { center.cancel(operation.id) }
                }
            }
        }
        .task(id: center.operations.map(\.id)) { await trackOperations() }
    }

    /// Records new operations, forgets ended ones, and wakes up when the next hidden row is due.
    private func trackOperations() async {
        let date = Date()
        let ids = Set(center.operations.map(\.id))
        var seen = firstSeen.filter { ids.contains($0.key) }
        for id in ids where seen[id] == nil { seen[id] = date }
        firstSeen = seen
        now = date
        guard let due = seen.values.map({ $0.addingTimeInterval(Self.delay) }).filter({ $0 > date }).min()
        else { return }
        try? await Task.sleep(for: .seconds(due.timeIntervalSince(date)))
        if !Task.isCancelled { now = max(Date(), due) }
    }
}

private struct OperationRow: View {
    let operation: FileOperationStatus
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(operation.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let progress = operation.progress, progress.totalBytes > 0 {
                    ProgressView(
                        value: Double(min(progress.completedBytes, progress.totalBytes)),
                        total: Double(progress.totalBytes))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let progress = operation.progress, progress.totalBytes > 0 {
                    Text(Self.byteText(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Stop"))
            .accessibilityLabel(String(localized: "Stop"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private static func byteText(_ progress: TransferProgress) -> String {
        let completed = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
        return String(localized: "\(completed) of \(total)")
    }
}
