import Foundation

/// The helper script that reopens the app after a language change, which only takes effect on a fresh launch.
public enum Relaunch {
    /// Polls until `pid` has exited, then opens the bundle. Waiting on the pid rather than a fixed sleep matters:
    /// `open` on a still-running app only activates it, and a committed quit still waits for cancelled operations
    /// and pending writes. The poll stops after 60 seconds so a stuck quit can't leave the helper running forever.
    ///
    /// The path goes in single quotes, so spaces and `"` or `$` in it are literal. A `'` in it is written `'\''`.
    public static func waitAndReopenCommand(pid: Int32, bundlePath: String) -> String {
        let quoted = "'" + bundlePath.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return """
            i=0
            while kill -0 \(pid) 2>/dev/null && [ "$i" -lt 300 ]; do
            sleep 0.2
            i=$((i+1))
            done
            open \(quoted)
            """
    }
}

/// A relaunch the user asked for, kept until the quit it started is either called off or goes ahead. The helper
/// that reopens the app starts only once the quit is committed: started earlier, a quit cancelled at the
/// running-operations prompt would leave it to reopen the app later, even after a deliberate quit.
public struct RelaunchRequest: Sendable {
    /// What the quit does once it is committed.
    public enum Decision: Sendable, CustomStringConvertible {
        /// Go on quitting: no relaunch was asked for, or the helper is running.
        case proceed
        /// The helper didn't start. Quitting now would lose the relaunch, so the quit is called off and the
        /// caller tells the user.
        case cancel(any Error)

        public var proceeds: Bool {
            if case .proceed = self { return true }
            return false
        }

        public var description: String {
            switch self {
            case .proceed: "proceed"
            case .cancel(let error): "cancel(\(error))"
            }
        }
    }

    public private(set) var isPending = false

    public init() {}

    /// The user asked to relaunch; the caller then starts the quit.
    public mutating func request() { isPending = true }

    /// The quit was called off ("Don't Quit"): the next quit is a plain one.
    public mutating func quitCancelled() { isPending = false }

    /// The quit is decided. Runs `startHelper` if a relaunch is pending, and uses up the request either way.
    public mutating func quitCommitted(startHelper: () throws -> Void) -> Decision {
        guard isPending else { return .proceed }
        isPending = false
        do {
            try startHelper()
            return .proceed
        } catch {
            return .cancel(error)
        }
    }
}
