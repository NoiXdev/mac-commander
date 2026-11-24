import Foundation
import Testing

@testable import MacCommanderCore

/// `AppVersion` parsing and ordering: a minimal SemVer-style parser
/// (major.minor.patch, optional pre-release, build metadata dropped) with
/// numeric-aware comparison.
@Suite("AppVersion")
struct AppVersionTests {
    @Test func parsesWithAndWithoutV() throws {
        let plain = try #require(AppVersion("0.1.1"))
        let prefixed = try #require(AppVersion("v0.1.1"))
        #expect(plain == prefixed)
        #expect(plain.description == "0.1.1")
    }

    @Test func parsesPreReleaseAndDropsBuildMetadata() throws {
        let preRelease = try #require(AppVersion("1.2.0-beta.1+abc"))
        #expect(preRelease.preRelease == "beta.1")

        let withBuildMetadata = try #require(AppVersion("1.2.0+abc"))
        let withoutBuildMetadata = try #require(AppVersion("1.2.0"))
        #expect(withBuildMetadata == withoutBuildMetadata)
    }

    @Test(arguments: ["", "1.2", "x.y.z", "1.2.3.4", "abc", "1.2.x", "v"])
    func rejectsGarbage(_ raw: String) {
        #expect(AppVersion(raw) == nil)
    }

    @Test func ordersNumerically() throws {
        let older = try #require(AppVersion("0.9.9"))
        let newer = try #require(AppVersion("0.10.0"))
        #expect(newer > older)
        let v123 = try #require(AppVersion("1.2.3"))
        let v1100 = try #require(AppVersion("1.10.0"))
        let v200 = try #require(AppVersion("2.0.0"))
        #expect(v123 < v1100)
        #expect(v1100 < v200)
    }

    @Test func preReleaseOrdersBeforeRelease() throws {
        let release = try #require(AppVersion("0.2.0"))
        #expect(try #require(AppVersion("0.2.0-beta.1")) < release)
        #expect(try #require(AppVersion("0.2.0-rc.1")) < release)
    }

    /// A GitHub tag is untrusted input; an unbounded or symbol-laden
    /// pre-release string could render unexpected content in the update
    /// dialog, so both fail to parse instead.
    @Test func rejectsTooLongPreRelease() {
        let tooLong = "a" + String(repeating: "b", count: 32)
        #expect(AppVersion("1.2.0-\(tooLong)") == nil)
        let atLimit = String(repeating: "c", count: 32)
        #expect(AppVersion("1.2.0-\(atLimit)") != nil)
    }

    @Test(arguments: ["beta!", "beta_1", "beta 1", "beta/1", "bêta"])
    func rejectsIllegalCharactersInPreRelease(_ preRelease: String) {
        #expect(AppVersion("1.2.0-\(preRelease)") == nil)
    }

    @Test func preReleaseFieldsCompare() throws {
        let alpha = try #require(AppVersion("1.2.0-alpha"))
        let beta = try #require(AppVersion("1.2.0-beta"))
        #expect(alpha < beta)

        let beta2 = try #require(AppVersion("1.2.0-beta.2"))
        let beta10 = try #require(AppVersion("1.2.0-beta.10"))
        #expect(beta2 < beta10)

        let beta1 = try #require(AppVersion("1.2.0-beta.1"))
        #expect(beta < beta1)
    }
}
