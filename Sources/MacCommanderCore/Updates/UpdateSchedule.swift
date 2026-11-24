import Foundation

/// Pure interval rule for the once-a-day automatic update check. No I/O.
public enum UpdateSchedule {
    /// `enabled == false` always skips. A never-checked app (`lastCheck == nil`)
    /// always checks. Otherwise checks only once at least 24 hours have passed
    /// since the last attempt (successful or not: the caller records the time
    /// after every attempt).
    public static func shouldCheck(now: Date, lastCheck: Date?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= 24 * 3600
    }
}
