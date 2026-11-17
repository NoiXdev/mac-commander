import Foundation
import Security

/// Share passwords as Keychain internet passwords in the format Finder/NetAuth use, so items are shared with
/// Finder: one item per server (no path attribute, so every share on a host uses the same password),
/// server = host, protocol = smb/afp/https/http, account = the username exactly as typed, label = host.
/// NFS has no Keychain protocol constant, so nothing is stored for it.
///
/// Server names match case-insensitively (Finder may have saved "FileServer.corp"; our hosts are lowercase).
/// `kSecMatchCaseInsensitive` does not apply to `kSecAttrServer` in the login keychain (verified: a lowercase
/// query with it doesn't find a mixed-case item, and `SecItemAdd` happily adds a lowercase twin), so every
/// operation first lists the items for protocol + account (attributes only, no secrets), picks the servers
/// equal to the host ignoring case, and then works on those exact names.
/// All `SecItem*` calls run on the blocking-I/O queue (`PathQueries.run`): they can wait on securityd.
public struct KeychainCredentialStore: CredentialStore {
    public init() {}

    public func password(for url: ShareURL, username: String) async -> String? {
        await PathQueries.run { Self.passwordNow(for: url, username: username) }
    }

    public func save(password: String, for url: ShareURL, username: String) async throws {
        let status = await PathQueries.run { Self.saveNow(password: password, for: url, username: username) }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func delete(for url: ShareURL, username: String) async {
        await PathQueries.run { Self.deleteNow(for: url, username: username) }
    }

    // MARK: Blocking implementations (call off main)

    static func passwordNow(for url: ShareURL, username: String) -> String? {
        for server in storedServers(for: url, username: username) {
            guard var query = baseQuery(for: url, username: username, server: server) else { return nil }
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
                let password = String(data: data, encoding: .utf8)
            {
                return password
            }
        }
        return nil
    }

    /// Updates every existing item for the host (whatever its case) and adds one only when there is none, so a
    /// second item never appears beside Finder's.
    static func saveNow(password: String, for url: ShareURL, username: String) -> OSStatus {
        guard let query = baseQuery(for: url, username: username, server: url.host) else { return errSecSuccess }
        let data = Data(password.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let servers = storedServers(for: url, username: username)
        guard servers.isEmpty else {
            var result = errSecSuccess
            for server in servers {
                let match = baseQuery(for: url, username: username, server: server) ?? query
                let status = SecItemUpdate(match as CFDictionary, update)
                if result == errSecSuccess { result = status }
            }
            return result
        }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = url.host
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecDuplicateItem else { return added }
        return SecItemUpdate(query as CFDictionary, update)
    }

    static func deleteNow(for url: ShareURL, username: String) {
        for server in storedServers(for: url, username: username) {
            guard let query = baseQuery(for: url, username: username, server: server) else { return }
            SecItemDelete(query as CFDictionary)
        }
    }

    /// The server names of existing items for this protocol and account that equal the host ignoring case,
    /// the exact spelling first. Reads attributes only, so it never touches a password.
    static func storedServers(for url: ShareURL, username: String) -> [String] {
        guard var query = baseQuery(for: url, username: username, server: nil) else { return [] }
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        else { return [] }
        var servers: [String] = []
        for item in items {
            guard let server = item[kSecAttrServer as String] as? String,
                server.caseInsensitiveCompare(url.host) == .orderedSame, !servers.contains(server)
            else { continue }
            servers.append(server)
        }
        return servers.filter { $0 == url.host } + servers.filter { $0 != url.host }
    }

    /// The attributes that identify the item (`server` nil leaves the server out), or nil when the scheme has
    /// no Keychain protocol (nfs).
    static func baseQuery(for url: ShareURL, username: String, server: String?) -> [String: Any]? {
        let secProtocol: CFString
        switch url.scheme {
        case "smb": secProtocol = kSecAttrProtocolSMB
        case "afp": secProtocol = kSecAttrProtocolAFP
        case "https": secProtocol = kSecAttrProtocolHTTPS
        case "http": secProtocol = kSecAttrProtocolHTTP
        default: return nil
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: secProtocol,
            kSecAttrAccount as String: username,
        ]
        if let server { query[kSecAttrServer as String] = server }
        return query
    }
}
