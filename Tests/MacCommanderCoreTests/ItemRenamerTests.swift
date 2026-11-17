import Testing
import Foundation
@testable import MacCommanderCore

@Suite struct ItemRenamerTests {
    @Test func renameBasic() throws {
        let dir = try TemporaryDirectory()
        let a = try dir.file("a.txt", contents: "x")
        let result = try ItemRenamer.rename(a, to: "  b.txt ")
        #expect(result.lastPathComponent == "b.txt")
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }

    @Test func renameCaseOnly() throws {
        let dir = try TemporaryDirectory()
        let a = try dir.file("readme.md")
        let result = try ItemRenamer.rename(a, to: "README.md")
        #expect(result.lastPathComponent == "README.md")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(names == ["README.md"])
    }

    @Test func renameRejectsEmptyAndSlash() throws {
        let dir = try TemporaryDirectory()
        let a = try dir.file("a.txt")
        #expect(throws: RenameError.emptyName) { try ItemRenamer.rename(a, to: "   ") }
        #expect(throws: RenameError.invalidCharacter) { try ItemRenamer.rename(a, to: "x/y") }
        #expect(throws: RenameError.invalidCharacter) { try ItemRenamer.rename(a, to: "x:y") }
    }

    @Test func renameRejectsExisting() throws {
        let dir = try TemporaryDirectory()
        let a = try dir.file("a.txt")
        try dir.file("b.txt")
        #expect(throws: RenameError.nameTaken("b.txt")) { try ItemRenamer.rename(a, to: "b.txt") }
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(RenameError.nameTaken("b.txt").message == "The name “b.txt” is already taken. Please choose a different name.")
    }

    @Test func renameSameNameIsNoOp() throws {
        let dir = try TemporaryDirectory()
        let a = try dir.file("a.txt")
        #expect(try ItemRenamer.rename(a, to: "a.txt") == a)
    }
}
