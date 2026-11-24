import Testing

@testable import MacCommanderCore

/// `NXReleaseVersion` carries the full tag version (pre-release suffix included); `CFBundleShortVersionString`
/// is three integers only. The update check needs the former, or a beta would compare as its final release.
@Suite("InstalledVersion")
struct InstalledVersionTests {
    @Test func releaseKeyWinsOverShortVersion() {
        let info: [String: Any] = ["NXReleaseVersion": "0.2.0-beta.1", "CFBundleShortVersionString": "0.2.0"]
        #expect(InstalledVersion.string(from: info) == "0.2.0-beta.1")
    }

    @Test func fallsBackToShortVersionWhenReleaseKeyIsMissing() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0"]
        #expect(InstalledVersion.string(from: info) == "0.1.0")
    }

    @Test func fallsBackToShortVersionWhenReleaseKeyIsEmpty() {
        let info: [String: Any] = ["NXReleaseVersion": "", "CFBundleShortVersionString": "0.1.0"]
        #expect(InstalledVersion.string(from: info) == "0.1.0")
    }

    @Test func nilWhenNeitherExists() {
        #expect(InstalledVersion.string(from: [:]) == nil)
        #expect(InstalledVersion.string(from: nil) == nil)
    }
}
