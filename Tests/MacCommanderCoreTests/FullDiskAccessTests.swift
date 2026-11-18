import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct FullDiskAccessTests {
    @Test func missingProbeCountsAsGranted() throws {
        let temp = try TemporaryDirectory()
        #expect(FullDiskAccess.isGranted(probe: temp.url.appendingPathComponent("nope")))
    }

    @Test func readableProbeIsGranted() throws {
        let temp = try TemporaryDirectory()
        #expect(FullDiskAccess.isGranted(probe: temp.url))
    }

    @Test func unreadableProbeIsNotGranted() throws {
        let temp = try TemporaryDirectory()
        let locked = temp.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        #expect(!FullDiskAccess.isGranted(probe: locked))
    }
}
