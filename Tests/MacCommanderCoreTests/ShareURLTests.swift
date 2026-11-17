import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct ShareURLTests {
    @Test func parsesForms() throws {
        let a = try #require(ShareURL("smb://NAS.local/Media"))
        #expect(a.host == "nas.local" && a.path == "/Media" && a.shareName == "Media")
        let b = try #require(ShareURL("smb://user:pw@nas/Media/sub/"))
        #expect(b.path == "/Media/sub" && b.url.absoluteString == "smb://nas/Media/sub")
        #expect(ShareURL("\\\\fs01\\Public")?.url.absoluteString == "smb://fs01/Public")
        #expect(ShareURL("nas/Media")?.scheme == "smb")
        #expect(ShareURL("https://dav.example.com/remote.php/dav") != nil)
        #expect(ShareURL("smb://[fe80::1]/x")?.host == "fe80::1")
        #expect(ShareURL("smb://[fe80::1]/x")?.url.absoluteString == "smb://[fe80::1]/x")
        #expect(ShareURL("nfs://srv/")?.path == "/")
        #expect(ShareURL("https://h")?.path == "/")
    }

    @Test func rejectsInvalid() {
        for s in ["ftp://x/y", "smb://", "smb://host", "", "   "] { #expect(ShareURL(s) == nil, "\(s)") }
    }

    @Test func percentAndSpaces() throws {
        let a = try #require(ShareURL("smb://nas/My%20Files"))
        #expect(a.path == "/My Files")
        #expect(ShareURL(a.url.absoluteString) == a)
        #expect(ShareURL("smb://nas/My Files")?.path == "/My Files")
    }

    @Test func matching() throws {
        let a = try #require(ShareURL("smb://NAS/media"))
        #expect(a.matches(try #require(ShareURL("smb://nas/Media"))))
        #expect(!a.matches(try #require(ShareURL("afp://nas/Media"))))
        #expect(!a.matches(try #require(ShareURL("smb://nas:4450/Media"))))
        #expect(a.matches(try #require(ShareURL("smb://nas:445/media"))))
        let h1 = try #require(ShareURL("https://h/A")), h2 = try #require(ShareURL("https://h/a"))
        #expect(!h1.matches(h2))
        let r = try #require(ShareURL(remountURL: URL(string: "smb://daniel@nas._smb._tcp.local/Media")!))
        #expect(r.host == "nas._smb._tcp.local" && r.url.absoluteString == "smb://nas._smb._tcp.local/Media")
    }

    @Test func probePorts() throws {
        #expect(try #require(ShareURL("smb://h/s")).probePort == 445)
        #expect(try #require(ShareURL("afp://h/s")).probePort == 548)
        #expect(try #require(ShareURL("nfs://h/s")).probePort == 2049)
        #expect(try #require(ShareURL("https://h/s")).probePort == 443)
        #expect(try #require(ShareURL("http://h/s")).probePort == 80)
        #expect(try #require(ShareURL("https://h:8443/s")).probePort == 8443)
    }

    @Test func displayNames() throws {
        #expect(try #require(ShareURL("smb://nas/Media/x")).displayName == "Media on nas")
        #expect(try #require(ShareURL("https://h/a/dav")).displayName == "h/dav")
        #expect(try #require(ShareURL("https://h")).displayName == "h")
    }

    @Test func codableRoundTrip() throws {
        let a = try #require(ShareURL("smb://nas:4450/My Files"))
        let data = try JSONEncoder().encode([a])
        #expect(try JSONDecoder().decode([ShareURL].self, from: data) == [a])
    }
}

@Suite struct ShareURLEdgeTests {
    @Test func edgeParsing() throws {
        #expect(ShareURL("smb://host/") == nil)
        #expect(ShareURL("smb://host:445") == nil)
        let a = try #require(ShareURL("SMB://Host/Sh"))
        #expect(a.url.absoluteString == "smb://host/Sh")
        #expect(ShareURL("smb://user:p@ss@host/x")?.host == "host")
        let z = try #require(ShareURL("smb://[fe80::1%25en0]/x"))
        #expect(ShareURL(z.url.absoluteString) == z)
        let data = try JSONEncoder().encode([z])
        #expect(try JSONDecoder().decode([ShareURL].self, from: data) == [z])
    }
}
