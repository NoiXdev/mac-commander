import Foundation
import Synchronization
import Testing
@testable import MacCommanderCore

private final class CountingFetcher: ReleaseFetcher, Sendable {
    private let calls = Mutex(0)
    private let result: Result<ReleaseInfo, UpdateCheckError>

    init(_ result: Result<ReleaseInfo, UpdateCheckError>) { self.result = result }

    var callCount: Int { calls.withLock { $0 } }

    func latestRelease() async throws -> ReleaseInfo {
        calls.withLock { $0 += 1 }
        return try result.get()
    }
}

private struct OtherError: Error {}

private struct ThrowingFetcher: ReleaseFetcher {
    func latestRelease() async throws -> ReleaseInfo { throw OtherError() }
}

@Suite("UpdateChecker")
struct UpdateCheckerTests {
    private static let url = URL(string: "https://github.com/NoiXdev/mac-commander/releases/tag/v0.2.0")!

    private func fetcher(tag: String) -> CountingFetcher {
        CountingFetcher(.success(ReleaseInfo(tag: tag, url: Self.url)))
    }

    @Test func newerReleaseIsAnUpdate() async throws {
        let result = await UpdateChecker(fetcher: fetcher(tag: "v0.2.0"), currentVersion: "0.1.1").check()
        let latest = try #require(AppVersion("0.2.0"))
        let current = try #require(AppVersion("0.1.1"))
        #expect(result == .updateAvailable(latest: latest, current: current, url: Self.url))
    }

    @Test func sameVersionIsUpToDate() async throws {
        let result = await UpdateChecker(fetcher: fetcher(tag: "v0.2.0"), currentVersion: "0.2.0").check()
        #expect(result == .upToDate(current: try #require(AppVersion("0.2.0"))))
    }

    @Test func olderReleaseIsUpToDate() async throws {
        let result = await UpdateChecker(fetcher: fetcher(tag: "v0.2.0"), currentVersion: "0.3.0").check()
        #expect(result == .upToDate(current: try #require(AppVersion("0.3.0"))))
    }

    @Test(arguments: [nil, "dev"] as [String?])
    func missingLocalVersionIsUnknown(_ version: String?) async {
        let fetcher = fetcher(tag: "v0.2.0")
        let result = await UpdateChecker(fetcher: fetcher, currentVersion: version).check()
        #expect(result == .unknownLocalVersion)
        #expect(fetcher.callCount == 0)
    }

    @Test func fetchErrorsPassThrough() async {
        let fetcher = CountingFetcher(.failure(.offline))
        let result = await UpdateChecker(fetcher: fetcher, currentVersion: "0.1.0").check()
        #expect(result == .failed(.offline))
    }

    @Test func untypedErrorsBecomeOffline() async {
        let result = await UpdateChecker(fetcher: ThrowingFetcher(), currentVersion: "0.1.0").check()
        #expect(result == .failed(.offline))
    }

    @Test func unparsableTagIsMalformed() async {
        let result = await UpdateChecker(fetcher: fetcher(tag: "latest"), currentVersion: "0.1.0").check()
        #expect(result == .failed(.malformedResponse))
    }
}
