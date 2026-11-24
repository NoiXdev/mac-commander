import Testing

@testable import MacCommanderCore

@Suite struct RelaunchTests {
    @Test func relaunchCommandWaitsForThePidAndQuotesThePath() {
        let path = #"/Applications/My "Mac" Commander.app"#
        let command = Relaunch.waitAndReopenCommand(pid: 4242, bundlePath: path)

        #expect(command.contains("kill -0 4242"))
        #expect(command.contains(#"open '/Applications/My "Mac" Commander.app'"#))
    }

    @Test func singleQuotesInThePathAreEscaped() {
        let command = Relaunch.waitAndReopenCommand(pid: 1, bundlePath: "/tmp/it's.app")
        #expect(command.contains(#"open '/tmp/it'\''s.app'"#))
    }

    // MARK: When the helper starts

    private struct HelperFailed: Error {}

    @Test func aPlainQuitStartsNoHelper() {
        var request = RelaunchRequest()
        var started = 0
        let decision = request.quitCommitted { started += 1 }
        #expect(started == 0)
        #expect(decision.proceeds)
    }

    @Test func aRequestedRelaunchStartsTheHelperOnceTheQuitIsCommitted() {
        var request = RelaunchRequest()
        request.request()
        #expect(request.isPending)
        var started = 0
        let decision = request.quitCommitted { started += 1 }
        #expect(started == 1)
        #expect(decision.proceeds)
        #expect(!request.isPending)
    }

    /// "Don't Quit" in the running-operations prompt: no helper is left to reopen the app later, and a later
    /// deliberate quit stays a quit.
    @Test func aCancelledQuitDropsTheRequest() {
        var request = RelaunchRequest()
        request.request()
        request.quitCancelled()
        #expect(!request.isPending)
        var started = 0
        let decision = request.quitCommitted { started += 1 }
        #expect(started == 0)
        #expect(decision.proceeds)
    }

    @Test func aSecondRelaunchAfterACancelStartsTheHelper() {
        var request = RelaunchRequest()
        request.request()
        request.quitCancelled()
        request.request()
        var started = 0
        _ = request.quitCommitted { started += 1 }
        #expect(started == 1)
    }

    /// Quitting without a helper would lose the relaunch, so the quit is called off and the caller tells the user.
    @Test func aHelperThatFailsToStartCancelsTheQuit() {
        var request = RelaunchRequest()
        request.request()
        let decision = request.quitCommitted { throw HelperFailed() }
        #expect(!decision.proceeds)
        if case .cancel(let error) = decision { #expect(error is HelperFailed) } else { Issue.record("\(decision)") }
        // The request is used up: the next quit is a plain quit unless the user asks to relaunch again.
        #expect(!request.isPending)
    }
}
