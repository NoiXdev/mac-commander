import Foundation
import Testing

@testable import MacCommanderCore

@Suite struct PreviewResourceURLTests {
    @Test func resourceURLRoundTrip() {
        let file = URL(fileURLWithPath: "/Users/a/My Docs/ä b.png")
        let url = PreviewResourceURL.url(for: file)
        #expect(url.absoluteString.hasPrefix("mcpreview://local/"))
        #expect(PreviewResourceURL.fileURL(for: url)?.path == file.path)
    }

    @Test func specialCharactersRoundTrip() {
        let file = URL(fileURLWithPath: "/Users/a/dir #1/a#b?c%d.png")
        let url = PreviewResourceURL.url(for: file)
        #expect(!url.absoluteString.dropFirst("mcpreview://local".count).contains("#"))
        #expect(!url.absoluteString.contains("?"))
        #expect(PreviewResourceURL.fileURL(for: url)?.path == file.path)
        // Also after a string round trip (as WebKit hands it to a scheme handler).
        let reparsed = URL(string: url.absoluteString)!
        #expect(PreviewResourceURL.fileURL(for: reparsed)?.path == file.path)
    }

    @Test func dotDotIsStandardized() {
        let url = URL(string: "mcpreview://local/Users/a/x/../y.png")!
        #expect(PreviewResourceURL.fileURL(for: url)?.path == "/Users/a/y.png")
    }

    @Test func foreignURLsAreRejected() {
        #expect(PreviewResourceURL.fileURL(for: URL(string: "https://local/x")!) == nil)
        #expect(PreviewResourceURL.fileURL(for: URL(string: "mcpreview://other/x")!) == nil)
    }
}
