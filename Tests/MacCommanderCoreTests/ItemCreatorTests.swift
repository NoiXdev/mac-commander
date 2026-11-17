import Testing
import Foundation
@testable import MacCommanderCore

@Suite struct ItemCreatorTests {
    @Test func createFolderTwice() throws {
        let dir = try TemporaryDirectory()
        let first = try ItemCreator.createFolder(in: dir.url)
        let second = try ItemCreator.createFolder(in: dir.url)
        #expect(first.lastPathComponent == "untitled folder")
        #expect(second.lastPathComponent == "untitled folder 2")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: second.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func createEmptyFileIsZeroBytes() throws {
        let dir = try TemporaryDirectory()
        let url = try ItemCreator.createEmptyFile(in: dir.url)
        #expect(url.lastPathComponent == "untitled.txt")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 0)
    }
}
