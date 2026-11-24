import Foundation
import Testing

@testable import MacCommanderCore

/// `UpdateSchedule.shouldCheck`: the pure once-a-day rule behind the
/// automatic update check.
@Suite("UpdateSchedule")
struct UpdateScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func disabledNeverChecks() {
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: nil, enabled: false) == false)
        let old = now.addingTimeInterval(-30 * 24 * 3600)
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: old, enabled: false) == false)
    }

    @Test func firstLaunchChecks() {
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: nil, enabled: true) == true)
    }

    @Test func checksOnlyAfterADay() {
        let at23h = now.addingTimeInterval(-23 * 3600)
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: at23h, enabled: true) == false)
        let at24h = now.addingTimeInterval(-24 * 3600)
        #expect(UpdateSchedule.shouldCheck(now: now, lastCheck: at24h, enabled: true) == true)
    }
}
