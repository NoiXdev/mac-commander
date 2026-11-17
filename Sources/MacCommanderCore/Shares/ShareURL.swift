import Foundation

/// A normalized network share address (smb, afp, nfs, https/http for WebDAV). Credentials, query and fragment
/// are never kept, so a value is safe to persist and to compare.
public struct ShareURL: Hashable, Sendable, Codable {
    /// Lowercase: smb, afp, nfs, https or http.
    public let scheme: String
    /// Lowercase; IPv6 literals are stored without brackets.
    public let host: String
    /// The explicit port only.
    public let port: Int?
    /// "/Share/Sub": leading slash, no trailing slash, percent-decoded.
    public let path: String

    static let supportedSchemes: Set<String> = ["smb", "afp", "nfs", "https", "http"]

    /// Accepts `scheme://[user[:pw]@]host[:port]/path`, `\\host\share\sub` (smb) and `host/share` (smb).
    /// Returns nil for unsupported schemes, a missing host, or (smb/afp) a missing share name.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("\\\\") {
            text = "smb://" + String(text.drop(while: { $0 == "\\" })).replacingOccurrences(of: "\\", with: "/")
        } else if !text.contains("://") {
            text = "smb://" + text
        }
        text = text.replacingOccurrences(of: " ", with: "%20")
        guard let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(), Self.supportedSchemes.contains(scheme),
            var host = components.host?.lowercased()
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return nil }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        if (scheme == "smb" || scheme == "afp") && parts.isEmpty { return nil }

        self.scheme = scheme
        self.host = host
        self.port = components.port
        self.path = "/" + parts.joined(separator: "/")
    }

    /// From a mount-time URL (for example the one a mounted volume reports); credentials are stripped.
    public init?(remountURL: URL) {
        self.init(remountURL.absoluteString)
    }

    /// Canonical URL, without credentials.
    public var url: URL {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let portPart = port.map { ":\($0)" } ?? ""
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(scheme)://\(hostPart)\(portPart)\(encoded)") ?? URL(string: "\(scheme)://invalid")!
    }

    /// The explicit port, or the scheme's default (445/548/2049/443/80).
    public var probePort: Int {
        if let port { return port }
        switch scheme {
        case "smb": return 445
        case "afp": return 548
        case "nfs": return 2049
        case "https": return 443
        default: return 80
        }
    }

    private var components: [Substring] { path.split(separator: "/") }

    /// The first path component (the host for an NFS root).
    public var shareName: String {
        components.first.map(String.init) ?? host
    }

    /// "<share> on <host>"; for http(s) the host plus the last path component, if any.
    public var displayName: String {
        switch scheme {
        case "http", "https":
            return components.last.map { "\(host)/\($0)" } ?? host
        default:
            return "\(shareName) on \(host)"
        }
    }

    /// Same scheme, host, effective port and path. The path is compared ignoring case for smb and afp.
    public func matches(_ other: ShareURL) -> Bool {
        guard scheme == other.scheme, host == other.host, probePort == other.probePort else { return false }
        if scheme == "smb" || scheme == "afp" {
            return path.caseInsensitiveCompare(other.path) == .orderedSame
        }
        return path == other.path
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let value = ShareURL(string) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid share URL: \(string)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }
}
