import Foundation

public enum DirectoryLoadError: Error, Equatable, Sendable {
    case permissionDenied(URL)
    case notFound(URL)
    case notADirectory(URL)
    case other(URL, String)
    /// The archive at the URL is encrypted and no password is known for it.
    case archivePasswordRequired(URL)
    case archiveIncorrectPassword(URL)
    /// The archive can't be listed; the string is bsdtar's message.
    case archiveUnreadable(URL, String)

    public var message: String {
        switch self {
        case .permissionDenied(let url):
            String(localized: "You don't have permission to see the contents of “\(url.lastPathComponent)”.")
        case .notFound(let url):
            String(localized: "The folder “\(url.lastPathComponent)” can't be found.")
        case .notADirectory(let url):
            String(localized: "“\(url.lastPathComponent)” is not a folder.")
        case .other(let url, let detail):
            String(localized: "The folder “\(url.lastPathComponent)” can't be opened: \(detail)")
        case .archivePasswordRequired(let url):
            String(localized: "“\(url.lastPathComponent)” is encrypted. Enter its password to see its contents.")
        case .archiveIncorrectPassword(let url):
            String(localized: "The password for “\(url.lastPathComponent)” is incorrect.")
        case .archiveUnreadable(let url, let detail):
            String(localized: "“\(url.lastPathComponent)” can’t be opened: \(detail)")
        }
    }
}

public struct DirectoryLoader: Sendable {
    public init() {}

    /// Lists a folder off the main actor. Results are unsorted.
    @concurrent
    public func contents(of url: URL, includeHidden: Bool) async throws(DirectoryLoadError) -> [FileItem] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: includeHidden ? [] : [.skipsHiddenFiles])
        } catch {
            throw Self.map(error, url: url)
        }
        // Entries that vanish mid-listing are skipped rather than failing the folder.
        return urls.compactMap { try? FileItem.load($0) }
    }

    private static func map(_ error: Error, url: URL) -> DirectoryLoadError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: ns.code) {
            case .fileReadNoPermission: return .permissionDenied(url)
            case .fileReadNoSuchFile, .fileNoSuchFile: return .notFound(url)
            case .fileReadUnknown:
                if let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError), posix.domain == NSPOSIXErrorDomain {
                    return mapPOSIX(Int32(posix.code), url: url, fallback: ns)
                }
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            return mapPOSIX(Int32(ns.code), url: url, fallback: ns)
        }
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
            return mapPOSIX(Int32(posix.code), url: url, fallback: ns)
        }
        return .other(url, ns.localizedDescription)
    }

    private static func mapPOSIX(_ code: Int32, url: URL, fallback: NSError) -> DirectoryLoadError {
        switch code {
        case ENOTDIR: .notADirectory(url)
        case EACCES, EPERM: .permissionDenied(url)
        case ENOENT: .notFound(url)
        default: .other(url, fallback.localizedDescription)
        }
    }
}
