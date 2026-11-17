import Foundation

public struct DropModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let option = DropModifiers(rawValue: 1 << 0)
    public static let command = DropModifiers(rawValue: 1 << 1)
}

/// Decides what a drop does: move on the same volume, copy across volumes, ⌥ forces copy, ⌘ forces move.
public enum DropPolicy {
    /// nil = refuse: destination is a source or inside one, or a move whose sources all already live in destination.
    public static func operation(
        for sources: [URL], into destination: URL, modifiers: DropModifiers,
        sameVolume: (URL, URL) -> Bool = FileTransfer.isSameVolume
    ) -> TransferMode? {
        guard !sources.isEmpty else { return nil }
        for source in sources where FileTransfer.isSourceContaining(destination, source: source) { return nil }

        let mode: TransferMode
        if modifiers.contains(.option) {
            mode = .copy
        } else if modifiers.contains(.command) {
            mode = .move
        } else {
            mode = sources.allSatisfy { sameVolume($0, destination) } ? .move : .copy
        }

        if mode == .move {
            let target = FileTransfer.canonicalPath(destination)
            let allInPlace = sources.allSatisfy {
                FileTransfer.canonicalPath($0.deletingLastPathComponent()) == target
            }
            if allInPlace { return nil }
        }
        return mode
    }
}
