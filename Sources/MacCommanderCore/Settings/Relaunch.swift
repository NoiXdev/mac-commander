import Foundation

/// The helper script that reopens the app after a language change, which only takes effect on a fresh launch.
public enum Relaunch {
    /// Polls until `pid` has exited, then opens the bundle. Waiting on the pid rather than a fixed sleep matters:
    /// `open` on a still-running app only activates it, and a quit that asks about running operations can take a
    /// while. The poll stops after 60 seconds so a stuck quit can't leave the helper running forever.
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
