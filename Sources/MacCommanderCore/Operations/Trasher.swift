import Foundation

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
}
