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

    @Test func didMoveRewritesPasteboardAsCopyOfDestinations() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pb)
        clipboard.cut(urls)
        clipboard.didPaste(mode: .move)
        let destinations = urls.map { URL(fileURLWithPath: "/tmp/mc-dest").appendingPathComponent($0.lastPathComponent) }
        clipboard.didMove(to: destinations)
        #expect(clipboard.fileURLs == destinations)
        #expect(clipboard.pasteMode(forceMove: false) == .copy)
    }

    @Test func didMoveRightAfterCutRewritesPasteboard() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pb)
        clipboard.cut(urls)
        let destinations = [URL(fileURLWithPath: "/tmp/mc-dest/mc-a.txt")]
        clipboard.didMove(to: destinations)
        #expect(clipboard.fileURLs == destinations)
        #expect(clipboard.pasteMode(forceMove: false) == .copy)
    }

    @Test func didMoveLeavesChangedPasteboardAlone() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pb)
        clipboard.cut(urls)
        clipboard.didPaste(mode: .move)
        let newer = [URL(fileURLWithPath: "/tmp/mc-newer.txt")]
        clipboard.copy(newer)
        clipboard.didMove(to: [URL(fileURLWithPath: "/tmp/mc-dest/mc-a.txt")])
        #expect(clipboard.fileURLs == newer)

        // Also when another app wrote to the pasteboard.
        clipboard.cut(urls)
        pb.clearContents()
        pb.writeObjects([newer[0] as NSURL])
        clipboard.didMove(to: [URL(fileURLWithPath: "/tmp/mc-dest/mc-a.txt")])
        #expect(clipboard.fileURLs == newer)
    }
}
