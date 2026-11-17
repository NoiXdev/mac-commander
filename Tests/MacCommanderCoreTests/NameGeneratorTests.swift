import Testing
import Foundation
@testable import MacCommanderCore

@Suite struct NameGeneratorTests {
    @Test func firstNameIsPlain() throws {
        let dir = try TemporaryDirectory()
        #expect(NameGenerator.uniqueName(base: "untitled", pathExtension: "txt", in: dir.url) == "untitled.txt")
        #expect(NameGenerator.uniqueName(base: "untitled folder", pathExtension: nil, in: dir.url) == "untitled folder")
    }

    @Test func skipsTakenNames() throws {
        let dir = try TemporaryDirectory()
        try dir.file("untitled.txt")
        try dir.file("untitled 2.txt")
        #expect(NameGenerator.uniqueName(base: "untitled", pathExtension: "txt", in: dir.url) == "untitled 3.txt")
    }

    @Test func hiddenFileCountsAsTaken() throws {
        let dir = try TemporaryDirectory()
        try dir.file(".untitled")
        #expect(NameGenerator.uniqueName(base: ".untitled", pathExtension: nil, in: dir.url) == ".untitled 2")
    }

    @Test func danglingSymlinkCountsAsTaken() throws {
        let dir = try TemporaryDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: dir.url.appendingPathComponent("untitled.txt").path, withDestinationPath: "/nonexistent/target")
        #expect(NameGenerator.uniqueName(base: "untitled", pathExtension: "txt", in: dir.url) == "untitled 2.txt")
    }

    @Test func copyNames() throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("report.txt")
        #expect(NameGenerator.copyName(for: "report.txt", isDirectory: false, in: tmp.url) == "report copy.txt")
        try tmp.file("report copy.txt")
        #expect(NameGenerator.copyName(for: "report.txt", isDirectory: false, in: tmp.url) == "report copy 2.txt")
        // Duplicating a copy continues its number instead of stacking "copy copy".
        #expect(NameGenerator.copyName(for: "report copy.txt", isDirectory: false, in: tmp.url) == "report copy 2.txt")
        try tmp.folder("my.folder")
        #expect(NameGenerator.copyName(for: "my.folder", isDirectory: true, in: tmp.url) == "my.folder copy")
        #expect(NameGenerator.copyName(for: ".zshrc", isDirectory: false, in: tmp.url) == ".zshrc copy")
    }

    @Test func keepBothNames() throws {
        let tmp = try TemporaryDirectory()
        try tmp.file("report.txt")
        #expect(NameGenerator.keepBothName(for: "report.txt", isDirectory: false, in: tmp.url) == "report 2.txt")
        try tmp.file("report 2.txt")
        #expect(NameGenerator.keepBothName(for: "report 2.txt", isDirectory: false, in: tmp.url) == "report 3.txt")
        #expect(NameGenerator.keepBothName(for: "Ärger.md", isDirectory: false, in: tmp.url) == "Ärger.md")
    }
}
