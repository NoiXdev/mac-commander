import Foundation

/// Production `ReleaseFetcher`: reads the latest release of
/// `NoiXdev/mac-commander` from the public GitHub REST API.
///
/// No token, no authenticated request, no user data. The request carries
/// only the URL plus `Accept`, `User-Agent` and a fixed `Accept-Language`
/// header. `Accept-Language` is pinned to `"en"` so the system locale never
/// travels with the request. The session defaults to an ephemeral
/// configuration so the request never touches the process-wide cookie store
/// or URL cache.
public struct GitHubReleaseFetcher: ReleaseFetcher {
    private static let releaseURL = URL(
        string: "https://api.github.com/repos/NoiXdev/mac-commander/releases/latest")!

    private let session: URLSession
    private let userAgentVersion: String

    /// - Parameter userAgentVersion: substituted into `User-Agent:
    ///   MacCommander/<version>`. The App layer passes
    ///   `CFBundleShortVersionString`; Core stays bundle-free.
    public init(
        session: URLSession = URLSession(configuration: .ephemeral),
        userAgentVersion: String
    ) {
        self.session = session
        self.userAgentVersion = userAgentVersion
    }

    public func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: Self.releaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacCommander/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Anything transport-level (no connection, DNS, timeout) is offline.
            throw UpdateCheckError.offline
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.malformedResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 403 || httpResponse.statusCode == 429,
                httpResponse.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            {
                throw UpdateCheckError.rateLimited
            }
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        guard let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data) else {
            throw UpdateCheckError.malformedResponse
        }
        // The URL comes from the API response, so it is validated before it
        // can reach `NSWorkspace.open`: https on exactly github.com, no
        // credentials or port, and inside this project's repository.
        guard let url = URL(string: payload.htmlURL),
            url.scheme == "https",
            url.host == "github.com",
            url.user == nil, url.password == nil, url.port == nil,
            url.path.hasPrefix("/NoiXdev/mac-commander/")
        else {
            throw UpdateCheckError.malformedResponse
        }
        return ReleaseInfo(tag: payload.tagName, url: url)
    }

    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
