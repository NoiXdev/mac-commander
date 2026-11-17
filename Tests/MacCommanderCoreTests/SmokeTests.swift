import Foundation
import Testing
@testable import MacCommanderCore

@Test func temporaryDirectoryCreatesFiles() throws {
    let dir = try TemporaryDirectory()
    let file = try dir.file("a.txt", contents: "hi")
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(try String(contentsOf: file, encoding: .utf8) == "hi")
}
