import Foundation
import Network
import Testing

@testable import MacCommanderCore

@Suite struct ShareAdaptersTests {
    @Test func mapsMountErrors() {
        for status: Int32 in [80, 13, -5045, -5046, -5999, -6004] {
            #expect(NetFSMounter.mapMountError(status) == .authenticationFailed, "\(status)")
        }
        for status: Int32 in [51, 65, 60, 61, 64] {
            #expect(NetFSMounter.mapMountError(status) == .unreachable, "\(status)")
        }
        for status: Int32 in [89, -128] {
            #expect(NetFSMounter.mapMountError(status) == .cancelled, "\(status)")
        }
        #expect(NetFSMounter.mapMountError(EEXIST) == .alreadyMounted)
        #expect(NetFSMounter.mapMountError(2) == .failed(String(cString: strerror(2))))
        #expect(NetFSMounter.mapMountError(-6600) == .failed("Error -6600 (kNetAuthErrorInternal)"))
        #expect(NetFSMounter.mapMountError(-6602) == .failed("Error -6602 (kNetAuthErrorMountFailed)"))
        for status: Int32 in [-6650, -6699, -5000, -1] {
            #expect(NetFSMounter.mapMountError(status) == .failed("Error \(status)"), "\(status)")
        }
    }

    @Test func proberReachesLocalListener() async throws {
        // Loopback only, so the test can't trigger a firewall prompt.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { $0.start(queue: .global()); $0.cancel() }
        let queue = DispatchQueue(label: "test.listener")
        let port: UInt16 = await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setOnce() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed, .cancelled:
                    if resumed.setOnce() { continuation.resume(returning: 0) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }
        try #require(port != 0)
        #expect(await TCPReachabilityProber().isReachable(host: "127.0.0.1", port: Int(port), timeout: .seconds(3)))
    }

    @Test func proberRefusedPortIsFalseQuickly() async throws {
        let port = try unusedLocalPort()
        let clock = ContinuousClock()
        let start = clock.now
        let reachable = await TCPReachabilityProber().isReachable(host: "127.0.0.1", port: port, timeout: .seconds(3))
        #expect(!reachable)
        #expect(clock.now - start < .seconds(1))
    }

    @Test func proberTimeoutIsBounded() async {
        let clock = ContinuousClock()
        let start = clock.now
        let reachable = await TCPReachabilityProber().isReachable(host: "10.255.255.1", port: 445, timeout: .seconds(3))
        #expect(!reachable)
        #expect(clock.now - start < .seconds(4))
    }

    /// An IP address always resolves; a name under the reserved `.invalid` domain never does.
    @Test func proberResolvesAddressesNotUnknownNames() async {
        #expect(await TCPReachabilityProber().resolves(host: "127.0.0.1"))
        #expect(await !TCPReachabilityProber().resolves(host: "maccommander-test.invalid"))
    }

    @Test func volumeListerKeepsOnlyNetworkShares() throws {
        let shares = SystemVolumeLister.shares(from: [
            ("apfs", "/dev/disk3s1s1", "/"),
            ("devfs", "devfs", "/dev"),
            ("msdos", "/dev/disk5s1", "/Volumes/USB"),
            ("autofs", "map auto_home", "/System/Volumes/Data/home"),
            ("smbfs", "//bob@NAS.local/Media", "/Volumes/Media"),
            ("smbfs", "garbage", "/Volumes/Garbage"),
            ("nfs", "files:/export/home", "/Volumes/home"),
        ])
        #expect(shares == [
            MountedShare(
                mountPoint: URL(fileURLWithPath: "/Volumes/Media", isDirectory: true),
                url: try #require(ShareURL("smb://nas.local/Media"))),
            MountedShare(
                mountPoint: URL(fileURLWithPath: "/Volumes/home", isDirectory: true),
                url: try #require(ShareURL("nfs://files/export/home"))),
        ])
    }

    @Test func volumeListerParsesMountedFrom() throws {
        func parsed(_ type: String, _ from: String) -> String? {
            SystemVolumeLister.shareURL(fsType: type, mountFrom: from)?.url.absoluteString
        }
        // smbfs: user, domain and password dropped; percent-encoded share names decoded.
        #expect(parsed("smbfs", "//nas/Share") == "smb://nas/Share")
        #expect(parsed("smbfs", "//bob@nas/Share") == "smb://nas/Share")
        #expect(parsed("smbfs", "//CORP;bob@fs01.corp.example/Team") == "smb://fs01.corp.example/Team")
        #expect(parsed("smbfs", "//bob:pw@nas:4450/Share") == "smb://nas:4450/Share")
        #expect(SystemVolumeLister.shareURL(fsType: "smbfs", mountFrom: "//nas/My%20Files")?.path == "/My Files")
        #expect(SystemVolumeLister.shareURL(fsType: "smbfs", mountFrom: "//nas/Caf%C3%A9")?.shareName == "Café")
        #expect(parsed("smbfs", "nas/Share") == nil)
        // afpfs: both spellings.
        #expect(parsed("afpfs", "afp://mac.local/Share") == "afp://mac.local/Share")
        #expect(parsed("afpfs", "afp://ann;AUTH=No%20User%20Authent@mac.local/Share") == "afp://mac.local/Share")
        #expect(parsed("afpfs", "//ann@mac.local/Share") == "afp://mac.local/Share")
        // nfs: host:/path, IPv6 in brackets, raw spaces.
        #expect(parsed("nfs", "files:/export/home") == "nfs://files/export/home")
        #expect(parsed("nfs", "[fe80::1]:/export") == "nfs://[fe80::1]/export")
        #expect(SystemVolumeLister.shareURL(fsType: "nfs", mountFrom: "files:/a b")?.path == "/a b")
        #expect(parsed("nfs", "files") == nil)
        // webdav: the URL as given.
        #expect(parsed("webdav", "https://dav.example.com/remote.php/dav") == "https://dav.example.com/remote.php/dav")
        #expect(parsed("webdav", "http://h:8080/dav") == "http://h:8080/dav")
        #expect(parsed("webdav", "ftp://h/x") == nil)
        // Anything else.
        #expect(parsed("apfs", "/dev/disk1s1") == nil)
        #expect(parsed("ftp", "ftp://h/x") == nil)
    }

    @Test func volumeListerRuns() async {
        let shares = await SystemVolumeLister().mountedShares()
        #expect(!shares.contains { $0.mountPoint.standardizedFileURL.path == "/" })
    }

    // The gated keychain tests each use their own server name: Swift Testing runs them in parallel.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MC_KEYCHAIN_TESTS"] == "1",
        "Writes to the login keychain; set MC_KEYCHAIN_TESTS=1"))
    func keychainRoundTrip() async throws {
        let store = KeychainCredentialStore()
        let url = try #require(ShareURL("smb://mc-test.invalid/McTest"))
        let username = #"CORP\tester"#
        defer {
            // `defer` can't await; delete synchronously through the same query the store builds.
            KeychainCredentialStore.deleteNow(for: url, username: username)
        }
        await store.delete(for: url, username: username)
        #expect(await store.password(for: url, username: username) == nil)

        try await store.save(password: "first", for: url, username: username)
        #expect(await store.password(for: url, username: username) == "first")
        try await store.save(password: "second", for: url, username: username)
        #expect(await store.password(for: url, username: username) == "second")
        #expect(await store.password(for: url, username: "tester") == nil)

        await store.delete(for: url, username: username)
        #expect(await store.password(for: url, username: username) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MC_KEYCHAIN_TESTS"] == "1",
        "Writes to the login keychain; set MC_KEYCHAIN_TESTS=1"))
    func keychainItemIsPerServer() async throws {
        let store = KeychainCredentialStore()
        let first = try #require(ShareURL("smb://mc-test-perserver.invalid/One"))
        let second = try #require(ShareURL("smb://mc-test-perserver.invalid/Two"))
        let username = #"CORP\tester"#
        defer { KeychainCredentialStore.deleteNow(for: first, username: username) }
        await store.delete(for: first, username: username)

        try await store.save(password: "shared", for: first, username: username)
        #expect(await store.password(for: second, username: username) == "shared")
        try await store.save(password: "changed", for: second, username: username)
        #expect(await store.password(for: first, username: username) == "changed")
        await store.delete(for: second, username: username)
        #expect(await store.password(for: first, username: username) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MC_KEYCHAIN_TESTS"] == "1",
        "Writes to the login keychain; set MC_KEYCHAIN_TESTS=1"))
    func keychainSaveUpdatesItemDifferingInCase() async throws {
        let store = KeychainCredentialStore()
        let url = try #require(ShareURL("smb://mc-test-case.invalid/Share"))
        let username = #"CORP\tester"#
        let account: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolSMB,
            kSecAttrAccount as String: username,
        ]
        let servers = ["MC-Test-Case.Invalid", "mc-test-case.invalid"]
        func deleteAll() {
            // Exact server names: `kSecMatchCaseInsensitive` doesn't apply to the server in the login keychain.
            for server in servers {
                SecItemDelete(account.merging([kSecAttrServer as String: server]) { $1 } as CFDictionary)
            }
        }
        defer { deleteAll() }
        deleteAll()

        // Seed the item the way Finder might have saved it: mixed-case server.
        let seed = account.merging([
            kSecAttrServer as String: "MC-Test-Case.Invalid",
            kSecAttrLabel as String: "MC-Test-Case.Invalid",
            kSecValueData as String: Data("old".utf8),
        ]) { $1 }
        try #require(SecItemAdd(seed as CFDictionary, nil) == errSecSuccess)

        try await store.save(password: "new", for: url, username: username)

        // Every item for this protocol and account, filtered by server ignoring case.
        var all = account
        all[kSecMatchLimit as String] = kSecMatchLimitAll
        all[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        try #require(SecItemCopyMatching(all as CFDictionary, &result) == errSecSuccess)
        let items = (result as? [[String: Any]] ?? []).filter {
            ($0[kSecAttrServer as String] as? String)?.caseInsensitiveCompare("mc-test-case.invalid") == .orderedSame
        }
        #expect(items.count == 1)
        #expect(items.first?[kSecAttrServer as String] as? String == "MC-Test-Case.Invalid")

        var seeded = account
        seeded[kSecAttrServer as String] = "MC-Test-Case.Invalid"
        seeded[kSecReturnData as String] = true
        var data: CFTypeRef?
        try #require(SecItemCopyMatching(seeded as CFDictionary, &data) == errSecSuccess)
        #expect((data as? Data).map { String(decoding: $0, as: UTF8.self) } == "new")
        #expect(await store.password(for: url, username: username) == "new")

        await store.delete(for: url, username: username)
        #expect(await store.password(for: url, username: username) == nil)
    }

    @Test func keychainSkipsNFS() async throws {
        let store = KeychainCredentialStore()
        let url = try #require(ShareURL("nfs://mc-test.invalid/export"))
        try await store.save(password: "x", for: url, username: "u")
        #expect(await store.password(for: url, username: "u") == nil)
    }
}

/// A port nothing listens on: bind to port 0, read the port, close.
private func unusedLocalPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EBADF) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
        }
    }
    guard bound else { throw POSIXError(.EADDRINUSE) }
    return Int(UInt16(bigEndian: addr.sin_port))
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func setOnce() -> Bool {
        lock.withLock {
            defer { set = true }
            return !set
        }
    }
}
