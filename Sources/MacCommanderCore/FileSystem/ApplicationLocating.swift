import AppKit
import Foundation

/// Finds apps for "Open With" rules. Calls ask Launch Services or the file system, which can block, so run
/// them on the blocking-I/O queue (`PathQueries.run`), never on the main actor.
public protocol ApplicationLocating: Sendable {
    /// The installed app with this bundle identifier, or nil.
    func applicationURL(bundleIdentifier: String) -> URL?
    /// Whether an application bundle is at `url`.
    func applicationExists(at url: URL) -> Bool
    /// The app macOS opens `url` with, or nil.
    func systemDefaultApplication(for url: URL) -> URL?
}

/// The live locator: Launch Services through `NSWorkspace`, bundle checks through Core Foundation. Stateless.
public struct WorkspaceApplicationLocator: ApplicationLocating {
    public init() {}

    public func applicationURL(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// True only for a bundle whose package type (Info.plist or PkgInfo) is `APPL`: a plain file or folder,
    /// even one named `X.app`, gives false, so a rule never hands files to something that can't open them.
    /// Reads the bundle fresh each time (no `Bundle` cache), following a symlinked app.
    public func applicationExists(at url: URL) -> Bool {
        var type: UInt32 = 0
        var creator: UInt32 = 0
        guard CFBundleGetPackageInfoInDirectory(url as CFURL, &type, &creator) else { return false }
        return type == Self.applicationPackageType
    }

    /// The four-character package type `APPL`.
    private static let applicationPackageType: UInt32 = 0x4150_504C

    public func systemDefaultApplication(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }
}
