import Testing
import Foundation
@testable import MacCommanderCore

@Suite(.english) struct ItemCreatorTests {
    @Test func newFolderUsesTheLanguagesName() throws {
        let dir = try TemporaryDirectory()
        let url = try L10n.$localeOverride.withValue("de") { try ItemCreator.createFolder(in: dir.url) }
        #expect(url.lastPathComponent == "Neuer Ordner")
    }

    @Test func newFileUsesTheLanguagesName() throws {
        let dir = try TemporaryDirectory()
        let url = try L10n.$localeOverride.withValue("de") { try ItemCreator.createEmptyFile(in: dir.url) }
        #expect(url.lastPathComponent == "Neue Datei.txt")
    }

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

    @Test func createEmptyFileNeverOverwrites() throws {
        let dir = try TemporaryDirectory()
        let existing = try dir.file("untitled.txt", contents: "keep")
        let url = try ItemCreator.createEmptyFile(in: dir.url)
        #expect(url.lastPathComponent == "untitled 2.txt")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
    }

    @Test func createEmptyFileSkipsDanglingSymlink() throws {
        let dir = try TemporaryDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: dir.url.appendingPathComponent("untitled.txt").path, withDestinationPath: "/nonexistent/target")
        let url = try ItemCreator.createEmptyFile(in: dir.url)
        #expect(url.lastPathComponent == "untitled 2.txt")
    }

    @Test func createFolderSkipsDanglingSymlink() throws {
        let dir = try TemporaryDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: dir.url.appendingPathComponent("untitled folder").path, withDestinationPath: "/nonexistent/target")
        let url = try ItemCreator.createFolder(in: dir.url)
        #expect(url.lastPathComponent == "untitled folder 2")
    }
}
