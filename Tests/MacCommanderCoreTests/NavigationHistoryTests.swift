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
