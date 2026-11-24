import Foundation
import Synchronization
import Testing
@testable import MacCommanderCore

/// `URLProtocol` stub registered only on a dedicated ephemeral session
/// configuration (never via `URLProtocol.registerClass`), so it cannot leak
/// into other suites. Its shared state sits behind a `Mutex`, and only this
/// suite (marked `.serialized`) uses it.
private final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)

    private struct State {
        var handler: Handler?
        var requests: [URLRequest] = []
    }

    private static let state = Mutex(State())

    static func install(_ handler: @escaping Handler) {
        state.withLock { $0 = State(handler: handler) }
    }

    static func clearHandler() {
        state.withLock { $0 = State() }
    }

    static var requests: [URLRequest] { state.withLock { $0.requests } }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.state.withLock { state -> Handler? in
            state.requests.append(request)
            return state.handler
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("GitHubReleaseFetcher", .serialized)
struct GitHubReleaseFetcherTests {
    private static let expectedURL = URL(
        string: "https://api.github.com/repos/NoiXdev/mac-commander/releases/latest")!
    private static let okJSON =
        #"{"tag_name":"v0.2.0","html_url":"https://github.com/NoiXdev/mac-commander/releases/tag/v0.2.0"}"#

    private func fetcher(version: String = "0.1.0") -> GitHubReleaseFetcher {
        GitHubReleaseFetcher(session: StubURLProtocol.makeSession(), userAgentVersion: version)
    }

    @Test func sendsExactlyTheDocumentedRequest() async throws {
        StubURLProtocol.install { _ in (200, [:], Data(Self.okJSON.utf8)) }
        _ = try await fetcher(version: "9.9.9").latestRelease()

        let request = try #require(StubURLProtocol.requests.first)
        #expect(StubURLProtocol.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url == Self.expectedURL)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "MacCommander/9.9.9")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.httpBody == nil)
    }

    @Test func parsesTagAndPage() async throws {
        StubURLProtocol.install { _ in (200, [:], Data(Self.okJSON.utf8)) }
        let release = try await fetcher().latestRelease()
        #expect(release.tag == "v0.2.0")
        #expect(release.url.absoluteString
            == "https://github.com/NoiXdev/mac-commander/releases/tag/v0.2.0")
    }

    @Test func rateLimitIsRecognised() async {
        StubURLProtocol.install { _ in (403, ["x-ratelimit-remaining": "0"], Data()) }
        await #expect(throws: UpdateCheckError.rateLimited) { try await fetcher().latestRelease() }

        StubURLProtocol.install { _ in (429, ["x-ratelimit-remaining": "0"], Data()) }
        await #expect(throws: UpdateCheckError.rateLimited) { try await fetcher().latestRelease() }
    }

    @Test func forbiddenWithoutRateLimitHeaderIsHTTPStatus() async {
        StubURLProtocol.install { _ in (403, [:], Data()) }
        await #expect(throws: UpdateCheckError.httpStatus(403)) { try await fetcher().latestRelease() }
    }

    @Test func otherStatusIsHTTPStatus() async {
        StubURLProtocol.install { _ in (404, [:], Data()) }
        await #expect(throws: UpdateCheckError.httpStatus(404)) { try await fetcher().latestRelease() }
    }

    @Test func transportErrorIsOffline() async {
        // No handler installed: the stub fails every load at transport level.
        StubURLProtocol.clearHandler()
        await #expect(throws: UpdateCheckError.offline) { try await fetcher().latestRelease() }
    }

    @Test func missingFieldsAreMalformed() async {
        StubURLProtocol.install { _ in (200, [:], Data(#"{"html_url":"https://github.com/x"}"#.utf8)) }
        await #expect(throws: UpdateCheckError.malformedResponse) { try await fetcher().latestRelease() }
    }

    @Test func fileURLIsRejectedAsMalformed() async {
        StubURLProtocol.install { _ in
            (200, [:], Data(#"{"tag_name":"v1.0.0","html_url":"file:///etc/passwd"}"#.utf8))
        }
        await #expect(throws: UpdateCheckError.malformedResponse) { try await fetcher().latestRelease() }
    }

    @Test(arguments: [
        "https://github.com/someone/mac-commander/releases/tag/v9.9.9",
        "https://github.com/NoiXdev/mac-commander-evil/releases/tag/v9.9.9",
        "https://user@github.com/NoiXdev/mac-commander/releases/tag/v9.9.9",
        "https://user:pw@github.com/NoiXdev/mac-commander/releases/tag/v9.9.9",
        "https://github.com:8443/NoiXdev/mac-commander/releases/tag/v9.9.9",
        "http://github.com/NoiXdev/mac-commander/releases/tag/v9.9.9",
        "https://www.github.com/NoiXdev/mac-commander/releases/tag/v9.9.9",
    ])
    func foreignOrDecoratedReleaseURLIsRejected(_ htmlURL: String) async {
        StubURLProtocol.install { _ in
            (200, [:], Data(#"{"tag_name":"v9.9.9","html_url":"\#(htmlURL)"}"#.utf8))
        }
        await #expect(throws: UpdateCheckError.malformedResponse) { try await fetcher().latestRelease() }
    }

    @Test func offHostURLIsRejectedAsMalformed() async {
        StubURLProtocol.install { _ in
            (200, [:], Data(#"{"tag_name":"v1.0.0","html_url":"https://evil.example/v1"}"#.utf8))
        }
        await #expect(throws: UpdateCheckError.malformedResponse) { try await fetcher().latestRelease() }
    }
}
