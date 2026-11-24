import AppKit
import MacCommanderCore

/// Quits the app and opens it again, after a language change.
@MainActor
enum AppRelauncher {
    /// The language in effect in this process: the stored choice, read once. `MacCommanderApp.init` touches it
    /// at startup, so a change made later (here or in System Settings) is never mistaken for the launch language.
    /// Nil without a bundle identifier (a bare `swift run`).
    static let launchLanguage: AppLanguage? = Bundle.main.bundleIdentifier.map { AppLanguageSetting(domain: $0).current }

    /// Starts a detached shell that waits for this process to exit and reopens the bundle, then quits. If the user
    /// cancels the quit, the shell's `open` just brings the running app forward.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            Relaunch.waitAndReopenCommand(
                pid: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath),
        ]
        try? task.run()
        NSApp.terminate(nil)
    }
}
