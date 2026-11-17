import Foundation

/// How the last connection to a share was authenticated. `automatic` = Kerberos ticket or existing Keychain item.
public enum AuthMethod: String, Codable, Sendable {
    case automatic, password, guest
}

/// A share kept in the sidebar. Never holds a password (those live in the Keychain only).
public struct SavedShare: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var url: ShareURL
    /// User-editable display name; defaults to `url.displayName`.
    public var name: String
    /// As typed (`DOMAIN\user`, `user@domain`); nil = none.
    public var username: String?
    public var lastAuth: AuthMethod
    public var autoReconnect: Bool
    /// Last seen mount point, to reconnect into the same subfolder.
    public var lastMountPath: String?

    public init(
        id: UUID = UUID(), url: ShareURL, name: String? = nil, username: String? = nil,
        lastAuth: AuthMethod = .automatic, autoReconnect: Bool = true, lastMountPath: String? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name ?? url.displayName
        self.username = username
        self.lastAuth = lastAuth
        self.autoReconnect = autoReconnect
        self.lastMountPath = lastMountPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, name, username, lastAuth, autoReconnect, lastMountPath
    }

    /// Lenient: only `url` is required; every other field falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let url = try c.decode(ShareURL.self, forKey: .url)
        self.url = url
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        self.name = (name?.isEmpty == false ? name : nil) ?? url.displayName
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? nil
        let auth = (try? c.decodeIfPresent(String.self, forKey: .lastAuth)) ?? nil
        lastAuth = auth.flatMap(AuthMethod.init(rawValue:)) ?? .automatic
        autoReconnect = (try? c.decodeIfPresent(Bool.self, forKey: .autoReconnect)) ?? true
        lastMountPath = (try? c.decodeIfPresent(String.self, forKey: .lastMountPath)) ?? nil
    }
}
