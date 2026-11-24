import AppKit
import MacCommanderCore
import Observation

/// The alert texts for each `UpdateCheckResult`.
enum UpdateAlertContent {
    static func title(for result: UpdateCheckResult) -> String {
        switch result {
        case .updateAvailable(let latest, _, _):
            return L10n.format("update.available.title", "MacCommander %@ is available", latest.description)
        case .upToDate:
            return L10n.string("update.upToDate.title", "MacCommander is up to date")
        case .unknownLocalVersion, .failed:
            return L10n.string("update.failed.title", "MacCommander couldn’t check for updates")
        }
    }

    /// `isHomebrew` adds the `brew upgrade` line to the update text; the other results ignore it.
    static func message(for result: UpdateCheckResult, isHomebrew: Bool) -> String {
        switch result {
        case .updateAvailable(_, let current, _):
            let installed = L10n.format("update.available.message", "You have %@.", current.description)
            guard isHomebrew else { return installed }
            let homebrew = L10n.string("update.available.homebrew", "Installed with Homebrew: run brew upgrade --cask maccommander")
            return installed + "\n" + homebrew
        case .upToDate(let current):
            return L10n.format("update.upToDate.message", "You have the latest version, %@.", current.description)
        case .unknownLocalVersion:
            return L10n.string("update.failed.unknownVersion", "This build has no version number to compare.")
        case .failed(let error):
            switch error {
            case .offline:
                return L10n.string("update.failed.offline", "You appear to be offline.")
            case .rateLimited:
                return L10n.string("update.failed.rateLimited", "GitHub’s limit for update checks has been reached. Try again later.")
            case .httpStatus(let status):
                return L10n.format("update.failed.httpStatus", "GitHub answered with status %lld.", status)
            case .malformedResponse:
                return L10n.string("update.failed.malformed", "GitHub’s answer couldn’t be read.")
            }
        }
    }
}

/// The app's one update check: the automatic check at launch, MacCommander ▸ Check for Updates… and Settings ▸
/// General ▸ Check Now all go through the same instance, owned by the app delegate, so two checks never overlap.
///
/// Nothing here runs on the main actor except the bookkeeping and the alert: the request runs in
/// `UpdateChecker.check()` (URLSession), the Homebrew check on `PathQueries.run`.
@MainActor
@Observable
final class UpdateCheckModel {
    /// True while a check runs, including while its manual alert is up. The menu item and Check Now are disabled.
    private(set) var isChecking = false

    /// One check. A manual check always shows its result in an app-modal alert. An automatic one shows only an
    /// available update, queued behind the other launch alerts; every other result stays silent.
    /// `lastUpdateCheck` is written after every attempt, whatever its result, so a dead network isn't retried at
    /// every launch.
    func check(manual: Bool, preferences: PreferencesStore) async {
        // Set before the first `await`, so two calls started together can't both get past it.
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        // Full release version (pre-release suffix included), also used for the User-Agent.
        let version = InstalledVersion.string(from: Bundle.main.infoDictionary)
        let checker = UpdateChecker(
            fetcher: GitHubReleaseFetcher(userAgentVersion: version ?? "unknown"), currentVersion: version)
        let result = await checker.check()
        preferences.preferences.lastUpdateCheck = Date()

        var isUpdate = false
        if case .updateAvailable = result { isUpdate = true }
        guard manual || isUpdate else { return }
        // Two `stat`s, so not on the main actor.
        let isHomebrew = isUpdate ? await PathQueries.run { HomebrewInstall.isCask() } : false

        if manual {
            Self.present(result, isHomebrew: isHomebrew)
        } else {
            LaunchAlertQueue.shared.enqueue { Self.present(result, isHomebrew: isHomebrew) }
        }
    }

    /// The launch check: when it's turned on and the last attempt is at least a day old, starts a check in its
    /// own task, so launch never waits for it.
    func checkAutomaticallyIfDue(preferences: PreferencesStore, now: Date = Date()) {
        guard
            UpdateSchedule.shouldCheck(
                now: now, lastCheck: preferences.preferences.lastUpdateCheck,
                enabled: preferences.preferences.updateCheckEnabled)
        else { return }
        Task { await check(manual: false, preferences: preferences) }
    }

    /// Shows the result now. For an update, Open Release Page (the default button) opens the release in the browser.
    private static func present(_ result: UpdateCheckResult, isHomebrew: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = UpdateAlertContent.title(for: result)
        alert.informativeText = UpdateAlertContent.message(for: result, isHomebrew: isHomebrew)
        if case .updateAvailable(_, _, let url) = result {
            alert.addButton(withTitle: L10n.string("update.available.openReleasePage", "Open Release Page"))
            alert.addButton(withTitle: L10n.string("update.available.later", "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.addButton(withTitle: L10n.string("update.ok", "OK"))
            alert.runModal()
        }
    }
}
