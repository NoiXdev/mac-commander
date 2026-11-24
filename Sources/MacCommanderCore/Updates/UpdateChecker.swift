import Foundation

/// The tag and release-page URL of the latest GitHub release.
public struct ReleaseInfo: Equatable, Sendable {
    public var tag: String
    public var url: URL

    public init(tag: String, url: URL) {
        self.tag = tag
        self.url = url
    }
}

/// Fetches metadata for the latest release. Kept behind a protocol so
/// `UpdateChecker` can be exercised in tests without any real network
/// access. The production implementation is `GitHubReleaseFetcher`.
public protocol ReleaseFetcher: Sendable {
    func latestRelease() async throws -> ReleaseInfo
}

/// Typed failure reasons for an update check attempt.
public enum UpdateCheckError: Error, Equatable, Sendable {
    /// The request could not reach the network (a transport-level failure).
    case offline
    /// A non-200, non-rate-limited HTTP response.
    case httpStatus(Int)
    /// GitHub's REST API rate limit was hit (403/429 with
    /// `x-ratelimit-remaining: 0`).
    case rateLimited
    /// The response was 200 but its JSON didn't contain what was expected
    /// (missing fields, a bad release URL or an unparsable release tag).
    case malformedResponse
}

/// Outcome of one `UpdateChecker.check()` call.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: AppVersion)
    case updateAvailable(latest: AppVersion, current: AppVersion, url: URL)
    /// The local version is missing or unparsable: an honest "unknown"
    /// result, never an update claim. The network is never contacted in
    /// this case.
    case unknownLocalVersion
    case failed(UpdateCheckError)
}

/// Compares the running app's version against the latest GitHub release.
///
/// Core stays bundle-free: the current version arrives as a plain
/// `String?` that the App layer reads from `Bundle.main`.
public struct UpdateChecker: Sendable {
    private let fetcher: any ReleaseFetcher
    private let currentVersion: String?

    public init(fetcher: any ReleaseFetcher, currentVersion: String?) {
        self.fetcher = fetcher
        self.currentVersion = currentVersion
    }

    /// Runs one check. A missing or unparsable `currentVersion` short-circuits
    /// to `.unknownLocalVersion` without calling the fetcher: there is
    /// nothing trustworthy to compare a fetched release against.
    public func check() async -> UpdateCheckResult {
        guard let currentVersion, let current = AppVersion(currentVersion) else {
            return .unknownLocalVersion
        }

        do {
            let release = try await fetcher.latestRelease()
            guard let latest = AppVersion(release.tag) else {
                return .failed(.malformedResponse)
            }
            if latest > current {
                return .updateAvailable(latest: latest, current: current, url: release.url)
            }
            return .upToDate(current: current)
        } catch let error as UpdateCheckError {
            return .failed(error)
        } catch {
            // A fetcher that doesn't map to `UpdateCheckError` is reported
            // as offline rather than leaking an untyped error.
            return .failed(.offline)
        }
    }
}
