import Foundation

/// What `ShareMounter.mount` is given. All nil and `guest == false` = automatic (Kerberos ticket or an existing
/// Keychain item, decided by the system).
public struct ShareCredentials: Sendable, Equatable {
    public var username: String?
    public var password: String?
    public var guest: Bool

    public init(username: String? = nil, password: String? = nil, guest: Bool = false) {
        self.username = username
        self.password = password
        self.guest = guest
    }

    public static let automatic = ShareCredentials()
    public static let asGuest = ShareCredentials(guest: true)
}

extension ShareCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never shows the password.
    public var description: String {
        let password = password == nil ? "nil" : "<redacted>"
        return "ShareCredentials(username: \(username.map { "\"\($0)\"" } ?? "nil"), password: \(password), "
            + "guest: \(guest))"
    }

    public var debugDescription: String { description }
}

public enum MountError: Error, Equatable, Sendable {
    /// `alreadyMounted`: the share is mounted already (EEXIST), for example by Finder; `ShareManager` then
    /// looks it up among the mounted volumes.
    case authenticationFailed, unreachable, cancelled, alreadyMounted, failed(String)
}

/// Mounts and unmounts shares without showing any system UI. Implementations do their own off-main work.
public protocol ShareMounter: Sendable {
    /// Returns the mount point.
    func mount(_ url: ShareURL, credentials: ShareCredentials) async throws(MountError) -> URL
    func unmount(_ mountPoint: URL, force: Bool) async throws(MountError)
}

/// A TCP connect to `host:port`, giving up after `timeout`.
public protocol ReachabilityProber: Sendable {
    func isReachable(host: String, port: Int, timeout: Duration) async -> Bool
    /// Whether a name lookup finds `host` (an IP address always counts as found).
    func resolves(host: String) async -> Bool
}

/// A network volume currently mounted on this Mac, by whatever app mounted it.
public struct MountedShare: Sendable, Equatable {
    public let mountPoint: URL
    public let url: ShareURL

    public init(mountPoint: URL, url: ShareURL) {
        self.mountPoint = mountPoint
        self.url = url
    }
}

public protocol MountedVolumeLister: Sendable {
    func mountedShares() async -> [MountedShare]
}

/// Share passwords (the Keychain in the app). `username` is used exactly as typed.
public protocol CredentialStore: Sendable {
    func password(for url: ShareURL, username: String) async -> String?
    func save(password: String, for url: ShareURL, username: String) async throws
    func delete(for url: ShareURL, username: String) async
}
