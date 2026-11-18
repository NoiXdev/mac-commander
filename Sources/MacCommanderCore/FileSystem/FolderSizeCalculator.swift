import Foundation

public struct FolderSize: Sendable, Equatable {
    public var bytes: Int64
    public var items: Int

    public init(bytes: Int64, items: Int) {
        self.bytes = bytes
        self.items = items
    }
}

public enum FolderSizeCalculator {
    /// Sums regular-file sizes (logical, `.fileSizeKey`) under `url` without following symlinks;
    /// `items` counts files and folders below `url` (a symlink is one item of 0 bytes), hidden files and
    /// package contents included. A root that is itself a symlink is followed (Get Info on a link to a
    /// folder measures the folder); nothing inside is. Unreadable subfolders are skipped (they still count
    /// as an item); an unreadable root throws. Throws CancellationError when cancelled.
    @concurrent public static func size(of url: URL) async throws -> FolderSize {
        try await size(of: url, onItem: nil)
    }

    /// Test hook: `onItem` gets the running item count, once per enumerated item, before the cancellation check.
    /// The walk runs on its own thread (`SerialQueueExecutor`): a folder on a dead share can block it for minutes.
    @concurrent static func size(of url: URL, onItem: (@Sendable (Int) -> Void)?) async throws -> FolderSize {
        try await SerialQueueExecutor.withOwnThread(label: "MacCommander op folder size") {
            try await walk(url, onItem: onItem)
        }
    }

    @concurrent private static func walk(_ url: URL, onItem: (@Sendable (Int) -> Void)?) async throws -> FolderSize {
        try Task.checkCancellation()
        let root = url.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // Throws for a root that can't be listed, rather than reporting an empty folder.
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return FolderSize(bytes: 0, items: 0) }

        var total = FolderSize(bytes: 0, items: 0)
        // `nextObject()` rather than `for in`: NSEnumerator's iterator is unavailable in async contexts.
        while let next = enumerator.nextObject() {
            guard let itemURL = next as? URL else { continue }
            total.items += 1
            onItem?(total.items)
            try Task.checkCancellation()
            let values = try? itemURL.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true, let size = values?.fileSize {
                total.bytes += Int64(size)
            }
        }
        return total
    }
}
