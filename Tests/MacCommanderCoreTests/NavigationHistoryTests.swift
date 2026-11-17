import Foundation
import Testing
@testable import MacCommanderCore

struct NavigationHistoryTests {
    private let a = URL(fileURLWithPath: "/a")
    private let b = URL(fileURLWithPath: "/b")
    private let c = URL(fileURLWithPath: "/c")

    @Test func visitClearsForwardStack() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        _ = h.goBack()
        #expect(h.canGoForward)
        h.visit(c)
        #expect(!h.canGoForward)
        #expect(h.current == c)
        #expect(h.goBack() == a)
    }

    @Test func visitingCurrentIsNoOp() {
        var h = NavigationHistory(start: a)
        h.visit(a)
        #expect(!h.canGoBack)
        #expect(h.current == a)
    }

    @Test func backThenForwardRestores() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        h.visit(c)
        #expect(h.goBack() == b)
        #expect(h.goBack() == a)
        #expect(h.goBack() == nil)
        #expect(h.goForward() == b)
        #expect(h.goForward() == c)
        #expect(h.goForward() == nil)
        #expect(h.current == c)
    }

    @Test func replaceCurrentKeepsStacks() {
        var h = NavigationHistory(start: a)
        h.visit(b)
        h.visit(c)
        _ = h.goBack()
        h.replaceCurrent(with: URL(fileURLWithPath: "/x"))
        #expect(h.current.path == "/x")
        #expect(h.canGoBack)
        #expect(h.canGoForward)
        #expect(h.goForward() == c)
        #expect(h.goBack() == URL(fileURLWithPath: "/x"))
        #expect(h.goBack() == a)
    }
}

struct NavigationHistoryRewriteTests {
    @Test func rewritePrefixRewritesAllEntriesUnderTheOldRoot() {
        var h = NavigationHistory(start: URL(fileURLWithPath: "/Users/me"))
        h.visit(URL(fileURLWithPath: "/Volumes/Media"))
        h.visit(URL(fileURLWithPath: "/Volumes/Media/a"))
        h.visit(URL(fileURLWithPath: "/Volumes/MediaX"))
        h.visit(URL(fileURLWithPath: "/Volumes/Media/a/b"))
        _ = h.goBack()
        _ = h.goBack()
        // back: /Users/me, /Volumes/Media; current: /Volumes/Media/a; forward: /Volumes/Media/a/b, /Volumes/MediaX

        h.rewritePrefix(from: URL(fileURLWithPath: "/Volumes/Media"), to: URL(fileURLWithPath: "/Volumes/Media-1"))

        #expect(h.current.path == "/Volumes/Media-1/a")
        #expect(h.goForward()?.path == "/Volumes/MediaX")
        #expect(h.goForward()?.path == "/Volumes/Media-1/a/b")
        _ = h.goBack()
        _ = h.goBack()
        #expect(h.goBack()?.path == "/Volumes/Media-1")
        #expect(h.goBack()?.path == "/Users/me")
    }
}
