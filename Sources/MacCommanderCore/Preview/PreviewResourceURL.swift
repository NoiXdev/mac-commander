import Foundation

/// `mcpreview://local/<percent-encoded absolute path>` URLs: how the preview web view addresses local files.
public enum PreviewResourceURL {
    public static let scheme = "mcpreview"
    static let host = "local"

    public static func url(for fileURL: URL) -> URL {
        url(forPath: fileURL.standardizedFileURL.path)
    }

    /// `path` must be absolute. A trailing "/" is kept (needed for `<base href>`).
    static func url(forPath path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        // Always valid: scheme, host and an absolute path.
        return components.url ?? URL(string: "\(scheme)://\(host)/")!
    }

    /// Inverse of `url(for:)`; nil for other schemes/hosts or non-absolute paths. `..` is resolved.
    public static func fileURL(for url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == scheme, components.host == host
        else { return nil }
        let path = components.path
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
