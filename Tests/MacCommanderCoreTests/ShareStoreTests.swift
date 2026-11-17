import Foundation
import Testing

@testable import MacCommanderCore

@MainActor @Suite struct ShareStoreTests {
    private func fileURL(_ dir: TemporaryDirectory) -> URL {
        dir.url.appendingPathComponent("sub/shares.json")
    }

    @Test func storeRoundTrip() async throws {
        let dir = try TemporaryDirectory()
        let file = fileURL(dir)
        let store = ShareStore(fileURL: file)
        var a = store.add(try #require(ShareURL("smb://nas/Media")), username: "daniel")
        a.lastAuth = .password
        a.autoReconnect = false
        a.lastMountPath = "/Volumes/Media/sub"
        a.name = "My NAS"
        store.update(a)
        let b = store.add(try #require(ShareURL("https://dav.example.com/x")), username: nil)
        store.decline(try #require(ShareURL("afp://old/Share")))
        await store.flush()

        let again = ShareStore(fileURL: file)
        #expect(again.shares == [a, b])
        #expect(again.declinedRemountURLs == [try #require(ShareURL("afp://old/Share"))])
    }

    @Test func addDeduplicates() throws {
        let dir = try TemporaryDirectory()
        let store = ShareStore(fileURL: fileURL(dir))
        let first = store.add(try #require(ShareURL("smb://nas/Media")), username: nil)
        let second = store.add(try #require(ShareURL("smb://NAS/media")), username: "bob")
        #expect(store.shares.count == 1)
        #expect(second.id == first.id && second.username == "bob")
        #expect(store.shares[0].username == "bob")
        _ = store.add(try #require(ShareURL("smb://nas/Media")), username: nil)
        #expect(store.shares[0].username == "bob")
    }

    @Test func removeWorks() throws {
        let dir = try TemporaryDirectory()
        let store = ShareStore(fileURL: fileURL(dir))
        let a = store.add(try #require(ShareURL("smb://nas/Media")), username: nil)
        store.remove(a.id)
        #expect(store.shares.isEmpty)
    }

    @Test func corruptFileMovedAside() async throws {
        let dir = try TemporaryDirectory()
        let file = try dir.file("shares.json", contents: "{nope")
        let store = ShareStore(fileURL: file)
        #expect(store.shares.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(names.contains { $0.hasPrefix("shares.json.corrupt-") })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        store.add(try #require(ShareURL("smb://nas/Media")), username: nil)
        await store.flush()
        #expect(ShareStore(fileURL: file).shares.count == 1)
    }

    @Test func lenientFields() throws {
        let dir = try TemporaryDirectory()
        let json = """
            {"version":1,"shares":[
              {"url":"smb://nas/Media","lastAuth":"kerberosMagic"},
              {"url":"ftp://bad/x"},
              {"nonsense":true},
              {"url":"smb://nas/Other","autoReconnect":false,"lastAuth":"guest"}
            ],"declined":["smb://x/y","bogus://"]}
            """
        let file = try dir.file("shares.json", contents: json)
        let store = ShareStore(fileURL: file)
        #expect(store.shares.count == 2)
        #expect(store.shares[0].autoReconnect == true && store.shares[0].lastAuth == .automatic)
        #expect(store.shares[0].name == "Media on nas")
        #expect(store.shares[1].autoReconnect == false && store.shares[1].lastAuth == .guest)
        #expect(store.declinedRemountURLs.count == 1)
    }

    @Test func noPasswordInFile() async throws {
        let dir = try TemporaryDirectory()
        let file = fileURL(dir)
        let store = ShareStore(fileURL: file)
        store.add(try #require(ShareURL("smb://nas/Media")), username: "daniel")
        await store.flush()
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(text.contains("daniel"))
        #expect(!text.lowercased().contains("password"))
    }
}
