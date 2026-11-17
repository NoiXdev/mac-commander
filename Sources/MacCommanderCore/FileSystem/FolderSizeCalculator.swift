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
    /// `items` counts files and folders below `url` (a symlink is one item of 0 bytes).
    /// Throws CancellationError when cancelled.
    @concurrent public static func size(of url: URL) async throws -> FolderSize {
        try Task.checkCancellation()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return FolderSize(bytes: 0, items: 0) }

        var total = FolderSize(bytes: 0, items: 0)
        // `nextObject()` rather than `for in`: NSEnumerator's iterator is unavailable in async contexts.
        while let next = enumerator.nextObject() {
            try Task.checkCancellation()
            guard let itemURL = next as? URL else { continue }
            total.items += 1
            let values = try? itemURL.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true, let size = values?.fileSize {
                total.bytes += Int64(size)
            }
        }
        return total
    }
}
