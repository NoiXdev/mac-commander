import Foundation
import Synchronization
import Testing

@testable import MacCommanderCore

struct FFmpegLocatorTests {
    private let first = URL(filePath: "/fake/a/ffmpeg")
    private let second = URL(filePath: "/fake/b/ffmpeg")

    @Test func missingWhenNoCandidate() async {
        let locator = FFmpegLocator(candidates: [first, second], isExecutable: { _ in false }, versionCheck: { _ in true })
        #expect(await locator.status() == .missing)
    }

    @Test func availableUsesFirstExecutable() async {
        let locator = FFmpegLocator(
            candidates: [first, second], isExecutable: { $0 == second }, versionCheck: { _ in true })
        #expect(await locator.status() == .available(second))
        #expect(locator.cachedStatus == .available(second))
    }

    @Test func brokenWhenVersionFails() async {
        let locator = FFmpegLocator(candidates: [first, second], isExecutable: { _ in true }, versionCheck: { _ in false })
        #expect(await locator.status() == .broken)
    }

    @Test func cachesFor60Seconds() async {
        let clock = Mutex(Date(timeIntervalSince1970: 1000))
        let checks = Mutex(0)
        let locator = FFmpegLocator(
            candidates: [first], isExecutable: { _ in true },
            versionCheck: { _ in
                checks.withLock { $0 += 1 }
                return true
            },
            now: { clock.withLock { $0 } })
        _ = await locator.status()
        clock.withLock { $0 = Date(timeIntervalSince1970: 1030) }
        _ = await locator.status()
        #expect(checks.withLock { $0 } == 1)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1061) }
        _ = await locator.status()
        #expect(checks.withLock { $0 } == 2)
    }

    @Test func cachedStatusNilBeforeFirstCheck() {
        let locator = FFmpegLocator(candidates: [first], isExecutable: { _ in true }, versionCheck: { _ in true })
        #expect(locator.cachedStatus == nil)
    }
}
