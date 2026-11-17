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

    @Test func volumeListerKeepsOnlyNetworkShares() throws {
        let file = { (path: String) in URL(fileURLWithPath: path, isDirectory: true) }
        let shares = SystemVolumeLister.shares(from: [
            (file("/"), true, nil),
            (file("/Volumes/USB"), true, URL(string: "smb://nas/Local")),
            (file("/Volumes/Unknown"), nil, URL(string: "smb://nas/Unknown")),
            (file("/Volumes/NoRemount"), false, nil),
            (file("/Volumes/FTP"), false, URL(string: "ftp://host/files")),
            (file("/Volumes/Media"), false, URL(string: "smb://user@NAS.local/Media")),
        ])
        let expected = try #require(ShareURL("smb://nas.local/Media"))
        #expect(shares == [MountedShare(mountPoint: file("/Volumes/Media"), url: expected)])
    }

    @Test func volumeListerRuns() async {
        let shares = await SystemVolumeLister().mountedShares()
        #expect(!shares.contains { $0.mountPoint.standardizedFileURL.path == "/" })
    }

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
        let first = try #require(ShareURL("smb://mc-test.invalid/One"))
        let second = try #require(ShareURL("smb://mc-test.invalid/Two"))
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
