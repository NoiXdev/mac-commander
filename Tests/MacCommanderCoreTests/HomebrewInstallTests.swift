import Testing
@testable import MacCommanderCore

@Suite("HomebrewInstall")
struct HomebrewInstallTests {
    @Test func detectsAppleSiliconCaskroom() {
        #expect(HomebrewInstall.isCask { $0 == "/opt/homebrew/Caskroom/maccommander" })
    }

    @Test func detectsIntelCaskroom() {
        #expect(HomebrewInstall.isCask { $0 == "/usr/local/Caskroom/maccommander" })
    }

    @Test func elseNotHomebrew() {
        #expect(!HomebrewInstall.isCask { _ in false })
    }
}
