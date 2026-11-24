import AppKit
import MacCommanderCore

/// Quits the app and opens it again, after a language change.
@MainActor
enum AppRelauncher {
    /// The language in effect in this process: the stored choice, read once. `MacCommanderApp.init` touches it
    /// at startup, so a change made later (here or in System Settings) is never mistaken for the launch language.
    /// Nil without a bundle identifier (a bare `swift run`).
    static let launchLanguage: AppLanguage? = Bundle.main.bundleIdentifier.map { AppLanguageSetting(domain: $0).current }

    private static var request = RelaunchRequest()

    /// Marks the relaunch and starts the quit. The helper that reopens the app starts only once the quit is
    /// committed (`quitCommitted`). If the user cancels the quit at the running-operations prompt, nothing
    /// reopens the app later: the relaunch is dropped and the button stays.
    static func relaunch() {
        request.request()
        NSApp.terminate(nil)
    }

    /// The quit was called off.
    static func quitCancelled() {
        request.quitCancelled()
    }

    /// The quit is decided. Starts the helper if a relaunch is pending. Returns false when the helper couldn't
    /// start: the quit must then be cancelled, since nothing would reopen the app. The user is told so.
    static func quitCommitted() -> Bool {
        guard !request.quitCommitted(startHelper: startHelper).proceeds else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("app.relaunch.failed.title", "MacCommander couldn’t be relaunched.")
        alert.informativeText = L10n.string("app.relaunch.failed.message", "Quit MacCommander and open it again for the new language to take effect.")
        alert.runModal()
        return false
    }

    /// A detached shell that waits for this process to exit and then reopens the bundle.
    private static func startHelper() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            Relaunch.waitAndReopenCommand(
                pid: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath),
        ]
        try task.run()
    }
}
