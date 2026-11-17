import AppKit
import Foundation
import Testing

@testable import MacCommanderCore

@MainActor
struct FileClipboardTests {
    private func makePasteboard() -> NSPasteboard { NSPasteboard(name: .init("test-\(UUID())")) }
    private let urls = [URL(fileURLWithPath: "/tmp/mc-a.txt"), URL(fileURLWithPath: "/tmp/mc-b.txt")]

    @Test func copyThenPasteIsCopy() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pb)
        clipboard.copy(urls)
        #expect(clipboard.pasteMode(forceMove: false) == .copy)
        #expect(clipboard.pasteMode(forceMove: true) == .move)
        #expect(clipboard.fileURLs == urls)
    }

    @Test func cutThenPasteIsMoveOnce() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pb)
        clipboard.cut(urls)
        #expect(clipboard.pasteMode(forceMove: false) == .move)
        clipboard.didPaste(mode: .move)
        #expect(clipboard.pasteMode(forceMove: false) == .copy)
    }

    @Test func externalChangeCancelsCut() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pb)
        clipboard.cut(urls)
        pb.clearContents()
        pb.writeObjects([urls[0] as NSURL])
        #expect(clipboard.pasteMode(forceMove: false) == .copy)
    }
}
