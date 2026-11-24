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
}
