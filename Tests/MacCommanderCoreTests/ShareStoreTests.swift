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
        let moved = try #require(names.first { $0.hasPrefix("shares.json.corrupt-") })
        #expect(moved.wholeMatch(of: /shares\.json\.corrupt-\d{8}-\d{6}/) != nil)
        #expect(try String(contentsOf: dir.url.appendingPathComponent(moved), encoding: .utf8) == "{nope")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        store.add(try #require(ShareURL("smb://nas/Media")), username: nil)
        await store.flush()
        #expect(ShareStore(fileURL: file).shares.count == 1)
    }

    @Test(.english) func lenientFields() throws {
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

    @Test func unreadableSharesAreKeptOnSave() async throws {
        let dir = try TemporaryDirectory()
        let json = """
            {"version":1,"shares":[
              {"url":"smb://nas/Media"},
              {"url":"ftp://bad/x","name":"Old FTP","extra":[1,2.5,null,{"deep":true}]},
              {"nonsense":true}
            ],"declined":[]}
            """
        let file = try dir.file("shares.json", contents: json)
        let store = ShareStore(fileURL: file)
        #expect(store.shares.count == 1)

        store.add(try #require(ShareURL("smb://nas/New")), username: nil)
        await store.flush()

        let data = try Data(contentsOf: file)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(object["shares"] as? [[String: Any]])
        #expect(entries.count == 4)
        let ftp = try #require(entries.first { $0["url"] as? String == "ftp://bad/x" })
        #expect(ftp["name"] as? String == "Old FTP")
        #expect((ftp["extra"] as? [Any])?.count == 4)
        #expect(entries.contains { $0["nonsense"] as? Bool == true })
        // Read again: still two readable shares, the unreadable ones still kept.
        let again = ShareStore(fileURL: file)
        #expect(again.shares.map(\.url.shareName) == ["Media", "New"])
        again.remove(again.shares[0].id)
        await again.flush()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect((after?["shares"] as? [Any])?.count == 3)
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

    @Test func corruptCollisionGetsSuffix() throws {
        let dir = try TemporaryDirectory()
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let file = try dir.file("shares.json", contents: "{one")
        _ = ShareStore(fileURL: file, now: { fixed })
        try dir.file("shares.json", contents: "{two")
        _ = ShareStore(fileURL: file, now: { fixed })
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).filter { $0.contains("corrupt") }
        #expect(names.count == 2)
        #expect(names.contains { $0.hasSuffix("-2") })
    }

    @Test func declineIsMatchBasedAndNotDuplicated() throws {
        let dir = try TemporaryDirectory()
        let store = ShareStore(fileURL: fileURL(dir))
        store.decline(try #require(ShareURL("smb://nas/Media")))
        store.decline(try #require(ShareURL("smb://nas:445/media")))
        #expect(store.declinedRemountURLs.count == 1)
        #expect(store.isDeclined(try #require(ShareURL("smb://NAS:445/MEDIA"))))
        #expect(!store.isDeclined(try #require(ShareURL("smb://nas/Other"))))
    }

    @Test func unreadableFileDisablesPersistence() async throws {
        let dir = try TemporaryDirectory()
        let file = try dir.file("shares.json", contents: "{\"version\":1,\"shares\":[{\"url\":\"smb://nas/Media\"}]}")
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let store = ShareStore(fileURL: file)
        #expect(store.shares.isEmpty)
        #expect(store.persistenceError != nil)
        store.add(try #require(ShareURL("smb://other/Share")), username: nil)
        await store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == ["shares.json"])
    }

    @Test func failedMoveAsideDisablesPersistence() async throws {
        let dir = try TemporaryDirectory()
        let sub = try dir.folder("ro")
        let file = sub.appendingPathComponent("shares.json")
        try "{nope".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path) }
        let store = ShareStore(fileURL: file)
        #expect(store.persistenceError != nil)
        store.add(try #require(ShareURL("smb://other/Share")), username: nil)
        await store.flush()
        #expect(try String(contentsOf: file, encoding: .utf8) == "{nope")
    }

    @Test func rapidWritesEndInFinalState() async throws {
        let dir = try TemporaryDirectory()
        let file = fileURL(dir)
        let store = ShareStore(fileURL: file)
        var last = store.add(try #require(ShareURL("smb://nas/Media")), username: nil)
        for i in 0..<20 {
            if i % 2 == 0 {
                last.name = "name \(i)"
                store.update(last)
            } else {
                store.add(try #require(ShareURL("smb://nas/Share\(i)")), username: nil)
            }
        }
        await store.flush()
        let again = ShareStore(fileURL: file)
        #expect(again.shares == store.shares)
        #expect(again.shares.count == 11)
        #expect(again.shares[0].name == "name 18")
    }
}
