import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct TagStoreTests {
    private func rawXattr(_ url: URL) -> Data? {
        let name = TagStore.attributeName
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read >= 0 ? data : nil
    }

    private func rawStrings(_ url: URL) throws -> [String]? {
        guard let data = rawXattr(url) else { return nil }
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
    }

    private func setRaw(_ strings: [String], on url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(url.path, TagStore.attributeName, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        #expect(result == 0)
    }

    @Test func decodeFinderFormat() throws {
        let tags = [FileTag(name: "Red", color: .red), FileTag(name: "Work", color: .none)]
        let decoded = TagStore.decode(TagStore.encode(tags))
        #expect(decoded == tags)
        #expect(decoded.map(\.color) == [.red, .none])

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Projekt", "Rot\n6", 5] as [Any], format: .binary, options: 0)
        let parsed = TagStore.decode(plist)
        #expect(parsed.map(\.name) == ["Projekt", "Rot"])
        #expect(parsed.map(\.color) == [.none, .red])
    }

    @Test func readWriteRoundTrip() throws {
        let dir = try TemporaryDirectory()
        let url = try dir.file("a.txt")
        let tags = [FileTag(name: "Red", color: .red), FileTag(name: "Work", color: .none)]
        try TagStore.writeNow(tags, to: url)
        #expect(TagStore.readNow(url) == tags)
        #expect(TagStore.readNow(url).map(\.color) == [.red, .none])
        #expect(try FileItem.load(url).tags.map(\.color) == [.red, .none])
        #expect(try FileItem.load(url).tags == tags)

        try TagStore.writeNow([], to: url)
        #expect(TagStore.readNow(url).isEmpty)
        #expect(getxattr(url.path, TagStore.attributeName, nil, 0, 0, XATTR_NOFOLLOW) == -1)
        #expect(errno == ENOATTR)
    }

    @Test func preservesUnknownEntries() async throws {
        let dir = try TemporaryDirectory()
        let url = try dir.file("a.txt")
        try setRaw(["Keep\n9", "Blue\n4"], on: url)
        try await TagStore.setTags(.add(FileTag(name: "Red", color: .red)), on: [url])
        #expect(try rawStrings(url) == ["Keep\n9", "Blue\n4", "Red\n6"])
        try await TagStore.setTags(.remove(FileTag(name: "Blue", color: .blue)), on: [url])
        #expect(try rawStrings(url) == ["Keep\n9", "Red\n6"])
    }

    @Test func addIsIdempotentCaseInsensitive() async throws {
        let dir = try TemporaryDirectory()
        let url = try dir.file("a.txt")
        try setRaw(["Red\n6"], on: url)
        try await TagStore.setTags(.add(FileTag(name: "red", color: .red)), on: [url])
        #expect(try rawStrings(url) == ["Red\n6"])
    }

    @Test func readOnlyThrows() async throws {
        let dir = try TemporaryDirectory()
        let url = try dir.file("a.txt")
        var values = URLResourceValues()
        values.isUserImmutable = true
        var mutable = url
        try mutable.setResourceValues(values)
        defer {
            var clear = URLResourceValues()
            clear.isUserImmutable = false
            try? mutable.setResourceValues(clear)
        }
        await #expect(throws: (any Error).self) {
            try await TagStore.setTags(.add(FileTag(name: "Red", color: .red)), on: [url])
        }
    }

    @Test func untaggedFileHasNoTagsAndNoCloudStatus() throws {
        let dir = try TemporaryDirectory()
        let item = try FileItem.load(try dir.file("a.txt"))
        #expect(item.tags.isEmpty)
        #expect(item.cloudStatus == nil)
    }

    @Test func cloudCallOnlyForCloudLocations() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(FileItem.mayBeInCloud(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/a.txt")))
        #expect(FileItem.mayBeInCloud(home.appendingPathComponent("Library/CloudStorage/Dropbox/a.txt")))
        let dir = try TemporaryDirectory()
        let url = try dir.file("a.txt")
        #expect(!FileItem.mayBeInCloud(url))
        #expect(try FileItem.load(url).cloudStatus == nil)
    }
}
