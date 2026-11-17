import Foundation
import Security

/// Share passwords as Keychain internet passwords in the format Finder uses, so items are shared with Finder:
/// server = host, protocol = smb/afp/https/http, account = the username exactly as typed, path = "/<share>" for
/// smb and afp, label = host. NFS has no Keychain protocol constant, so nothing is stored for it.
/// All `SecItem*` calls run on the blocking-I/O queue (`PathQueries.run`): they can wait on securityd.
public struct KeychainCredentialStore: CredentialStore {
    public init() {}

    public func password(for url: ShareURL, username: String) async -> String? {
        guard var query = Self.baseQuery(for: url, username: username) else { return nil }
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let request = SendableQuery(query)
        return await PathQueries.run {
            var item: CFTypeRef?
            guard SecItemCopyMatching(request.dictionary as CFDictionary, &item) == errSecSuccess,
                let data = item as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    public func save(password: String, for url: ShareURL, username: String) async throws {
        guard let query = Self.baseQuery(for: url, username: username) else { return }
        let data = Data(password.utf8)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = url.host
        let add = SendableQuery(attributes)
        let match = SendableQuery(query)
        let status: OSStatus = await PathQueries.run {
            let added = SecItemAdd(add.dictionary as CFDictionary, nil)
            guard added == errSecDuplicateItem else { return added }
            let update = [kSecValueData as String: data] as CFDictionary
            return SecItemUpdate(match.dictionary as CFDictionary, update)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func delete(for url: ShareURL, username: String) async {
        await PathQueries.run { Self.deleteNow(for: url, username: username) }
    }

    /// Synchronous delete (blocks: call off main). For cleanup paths that can't await.
    static func deleteNow(for url: ShareURL, username: String) {
        guard let query = baseQuery(for: url, username: username) else { return }
        SecItemDelete(query as CFDictionary)
    }

    /// The attributes that identify the item, or nil when the scheme has no Keychain protocol (nfs).
    static func baseQuery(for url: ShareURL, username: String) -> [String: Any]? {
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
            kSecAttrServer as String: url.host,
            kSecAttrProtocol as String: secProtocol,
            kSecAttrAccount as String: username,
        ]
        if url.scheme == "smb" || url.scheme == "afp" {
            query[kSecAttrPath as String] = "/" + url.shareName
        }
        return query
    }
}

/// A Keychain query dictionary handed to the blocking queue. Holds only CF property-list values.
private struct SendableQuery: @unchecked Sendable {
    let dictionary: [String: Any]

    init(_ dictionary: [String: Any]) {
        self.dictionary = dictionary
    }
}
