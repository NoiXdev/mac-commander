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
}
