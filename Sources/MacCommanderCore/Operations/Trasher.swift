import Foundation

public struct TrashResult: Sendable, Equatable {
    public var trashed: [TrashedItem]
    public var failures: [TrashFailure]

    public init(trashed: [TrashedItem], failures: [TrashFailure]) {
        self.trashed = trashed
        self.failures = failures
    }
}

public struct TrashFailure: Sendable, Equatable {
    public let url: URL
    public let message: String

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

public enum Trasher {
    /// Moves `url` to the user's Trash and returns where it ended up there.
    /// Throws if the Trash did not report a resulting location.
    public static let systemTrash: @Sendable (URL) throws -> URL = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let resulting else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return resulting as URL
    }

    /// Moves each item to the Trash off the main actor. A failing item does not stop the others;
    /// `trashed` records where each item went, so it can be put back. Cancelling stops before the next
    /// item; items not reached are left where they are (neither trashed nor failures).
    @concurrent public static func trash(
        _ urls: [URL], using trash: @Sendable (URL) throws -> URL = systemTrash
    ) async -> TrashResult {
        var result = TrashResult(trashed: [], failures: [])
        for url in urls {
            if Task.isCancelled { break }
            do {
                result.trashed.append(TrashedItem(original: url, trashed: try trash(url)))
            } catch {
                result.failures.append(TrashFailure(url: url, message: error.localizedDescription))
            }
        }
        return result
    }
}
