# Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MacCommander checks GitHub for a newer finished release: automatically once a day at launch (on by default) and on demand from the app menu and Settings. When an update is found, it shows an alert with a link to the release page and, for Homebrew installs, the `brew upgrade` command.

**Architecture:** Core gets an `Updates` folder ported from macSCP (`~/_dev/macSCP/Sources/macSCPCore/Updates/`). It holds a pure version and schedule logic, a `ReleaseFetcher` protocol with a GitHub implementation, and an `UpdateChecker` that returns a typed result. The app gets an `@MainActor @Observable UpdateCheckModel`, ported from macSCP's `UpdateCheckModel.swift`, which drives the menu item, the Settings rows and the alerts.

**Tech Stack:** Swift 6.4, SwiftUI + AppKit, `URLSession`, Swift Testing (`scripts/test.sh`), `L10n` from plan 11.

**Spec:** `docs/superpowers/specs/2026-11-24-update-check-design.md`

## Global Constraints

- Branch `improvements`. Conventional Commits, no scope. Commit only once the user has approved committing. Footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- macOS 15+. No new package dependencies and no new entitlements.
- The request is exactly `GET https://api.github.com/repos/NoiXdev/mac-commander/releases/latest` with these headers and nothing else (no token, no cookies):
  - `Accept: application/vnd.github+json`
  - `User-Agent: MacCommander/<CFBundleShortVersionString>`
  - `Accept-Language: en`
- Automatic checks: at most once per 24 hours, counted from the last *attempt*. Only an available update shows UI. Manual checks always show their result.
- An unreadable or missing local version gives "unknown", never an update claim.
- No network or file-system work on the main actor. Tests never touch the real network.
- All user-visible strings go through `L10n` with named keys in en, de, fr and pl, following plan 11's rules:
  - Finder and macOS wording.
  - German uses the informal du.
  - In de, a U+00A0 goes before "…".
  - In fr, a U+00A0 goes before ; : ? ! and inside « ».

  `SourceKeyTests`, `LocalizationCatalogTests` and `RawStringGuardTests` must pass.
- Tests that compare English text use `.english`.
- User docs (noix-docs) are not touched here.

## Review Focus

- **Offline at launch:** no alert, and the next launch within 24 hours doesn't retry. Pinned by `UpdateScheduleTests.checksOnlyAfterADay` (Task 1) and the model ruling in Task 3.
- **A pre-release tag on the local build** (`0.2.0-beta.1`) against the latest release `v0.2.0`: an update is available. A local `0.2.0` against `v0.2.0-rc.1` is not newer. Pinned by `AppVersionTests.preReleaseOrdersBeforeRelease` (Task 1).
- **A GitHub rate limit** (403 with `x-ratelimit-remaining: 0`) reads as "rate limited", not as a generic HTTP error. Pinned by `GitHubReleaseFetcherTests.rateLimitIsRecognised` (Task 2).
- **A Homebrew install** shows the `brew upgrade --cask maccommander` line, and other installs don't. Pinned by `HomebrewInstallTests` (Task 2).
- **Preferences from an older build** have no update fields, so the check is on and has never run. Pinned by `PreferencesTests.updateCheckDefaults` (Task 1).

---

### Task 1: Versions, schedule and the two preferences

**Files:**
- Create: `Sources/MacCommanderCore/Updates/AppVersion.swift`, `Sources/MacCommanderCore/Updates/UpdateSchedule.swift`
- Modify: `Sources/MacCommanderCore/Settings/Preferences.swift`
- Test: `Tests/MacCommanderCoreTests/AppVersionTests.swift`, `Tests/MacCommanderCoreTests/UpdateScheduleTests.swift`, `Tests/MacCommanderCoreTests/PreferencesTests.swift`

**Interfaces:**
- Produces:
  - `public struct AppVersion: Comparable, Sendable, CustomStringConvertible`, with `init?(_ string: String)`. It accepts an optional leading `v` and `MAJOR.MINOR.PATCH` with an optional `-prerelease`, and compares by semver, where a pre-release orders before its release. Port it from macSCP's `AppVersion.swift`.
  - `public enum UpdateSchedule { public static func shouldCheck(now: Date, lastCheck: Date?, enabled: Bool) -> Bool }`, the same as macSCP's.
  - `Preferences.updateCheckEnabled: Bool` (default `true`) and `Preferences.lastUpdateCheck: Date?` (default `nil`), both decoded leniently.

- [ ] **Step 1: Write the failing tests.**
  - `AppVersionTests`:
    - `parsesWithAndWithoutV`: `"v0.1.1"` and `"0.1.1"` are equal.
    - `rejectsGarbage`: `""`, `"1.2"`, `"x.y.z"` and `"1.2.3.4"` give nil.
    - `ordersNumerically`: `0.10.0 > 0.9.9`.
    - `preReleaseOrdersBeforeRelease`: `0.2.0-beta.1 < 0.2.0`, and `0.2.0-rc.1 < 0.2.0`.
  - `UpdateScheduleTests`:
    - `disabledNeverChecks`.
    - `firstLaunchChecks`: `lastCheck: nil` gives true.
    - `checksOnlyAfterADay`: 23 h gives false, 24 h gives true.
  - `PreferencesTests.updateCheckDefaults`: `{}` decodes to enabled `true` and last check `nil`. A round trip keeps a set date.
- [ ] **Step 2: Run** `scripts/test.sh --filter 'AppVersionTests|UpdateScheduleTests|PreferencesTests'`. Expected: a compile failure.
- [ ] **Step 3: Implement.** Port the two types from macSCP and adapt their doc comments. Add both fields to `Preferences`: the memberwise init defaults, `CodingKeys`, and the lenient `init(from:)`.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: compare app versions and schedule a daily update check`

### Task 2: Fetching and checking

**Files:**
- Create:
  - `Sources/MacCommanderCore/Updates/UpdateChecker.swift`: `ReleaseInfo`, `ReleaseFetcher`, `UpdateCheckError`, `UpdateCheckResult` and `UpdateChecker`
  - `Sources/MacCommanderCore/Updates/GitHubReleaseFetcher.swift`
  - `Sources/MacCommanderCore/Updates/HomebrewInstall.swift`
- Test: `Tests/MacCommanderCoreTests/UpdateCheckerTests.swift`, `Tests/MacCommanderCoreTests/GitHubReleaseFetcherTests.swift`, `Tests/MacCommanderCoreTests/HomebrewInstallTests.swift`

**Interfaces:**
- Consumes: Task 1's `AppVersion`.
- Produces, with the shapes ported from macSCP's `UpdateChecker.swift` and `GitHubReleaseFetcher.swift`:
  - `public struct ReleaseInfo: Equatable, Sendable { tag: String; url: URL }`
  - `public protocol ReleaseFetcher: Sendable { func latestRelease() async throws -> ReleaseInfo }`
  - `public enum UpdateCheckError: Error, Equatable, Sendable { case offline, httpStatus(Int), rateLimited, malformedResponse }`
  - `public enum UpdateCheckResult: Equatable, Sendable`, with these cases:
    - `case upToDate(current: AppVersion)`
    - `case updateAvailable(latest: AppVersion, current: AppVersion, url: URL)`
    - `case unknownLocalVersion`
    - `case failed(UpdateCheckError)`
  - `public struct UpdateChecker: Sendable { init(fetcher: any ReleaseFetcher, currentVersion: String?); func check() async -> UpdateCheckResult }`
  - `public struct GitHubReleaseFetcher: ReleaseFetcher { init(session: URLSession = .shared, userAgentVersion: String) }`. It uses the exact URL and headers from Global Constraints and reads `tag_name` and `html_url`.
  - `public enum HomebrewInstall { public static func isCask(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool }`. It is true when `/opt/homebrew/Caskroom/maccommander` or `/usr/local/Caskroom/maccommander` exists.

- [ ] **Step 1: Write the failing tests.**
  - `UpdateCheckerTests`, using a fake fetcher:
    - `newerReleaseIsAnUpdate`: local 0.1.1 against `v0.2.0` gives `.updateAvailable` with the release URL.
    - `sameVersionIsUpToDate`.
    - `olderReleaseIsUpToDate`: local 0.3.0 against `v0.2.0`.
    - `missingLocalVersionIsUnknown`: nil and `"dev"` give `.unknownLocalVersion`, and the fetcher is not called.
    - `fetchErrorsPassThrough`: `.offline` gives `.failed(.offline)`.
    - `unparsableTagIsMalformed`: `"latest"` gives `.failed(.malformedResponse)`.
  - `GitHubReleaseFetcherTests`, using a `URLProtocol` stub and a dedicated `URLSession` configuration (no real network):
    - `sendsExactlyTheDocumentedRequest`: method, URL and the three headers, with no `Authorization` header.
    - `parsesTagAndPage`.
    - `rateLimitIsRecognised`: 403 with `x-ratelimit-remaining: 0`, and 429, give `.rateLimited`.
    - `otherStatusIsHTTPStatus`: 404 gives `.httpStatus(404)`.
    - `transportErrorIsOffline`.
    - `missingFieldsAreMalformed`.
  - `HomebrewInstallTests`:
    - `detectsAppleSiliconCaskroom`.
    - `detectsIntelCaskroom`.
    - `elseNotHomebrew`.
- [ ] **Step 2: Run** `scripts/test.sh --filter 'UpdateCheckerTests|GitHubReleaseFetcherTests|HomebrewInstallTests'`. Expected: a compile failure.
- [ ] **Step 3: Implement.** Port the types from macSCP, adapting the repository path and the `User-Agent` name.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: check GitHub for the latest MacCommander release`

### Task 3: Menu, Settings, launch check and alerts

**Files:**
- Create: `Sources/MacCommander/App/UpdateCheckModel.swift`
- Modify:
  - `Sources/MacCommander/App/MacCommanderApp.swift`: owns the model, runs the launch check, passes the model to the commands and Settings.
  - `Sources/MacCommander/App/BrowserCommands.swift`: adds `CommandGroup(after: .appInfo)`.
  - `Sources/MacCommander/Settings/GeneralSettings.swift`
  - `Sources/MacCommanderCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: none in the app target, which tests can't import. The decision logic sits in Core (Tasks 1–2). This task's evidence is `swift build` with no warnings, a full green `scripts/test.sh`, and the user's hand check.

**Interfaces:**
- Consumes: Task 1's `UpdateSchedule` and the `Preferences` fields, and Task 2's `UpdateChecker`, `GitHubReleaseFetcher`, `UpdateCheckResult` and `HomebrewInstall`.

- [ ] **Step 1: Model.** Port macSCP's `UpdateCheckModel` and adapt it:
  - It is `@MainActor @Observable`, with `isChecking`.
  - `check(manual: Bool, preferences: PreferencesStore) async` reads `CFBundleShortVersionString` from `Bundle.main`. It writes `lastUpdateCheck = now` after every attempt, manual or automatic.
  - `checkAutomaticallyIfDue(preferences:now:)` uses `UpdateSchedule` and shows UI only for `.updateAvailable`.
  - A manual check always shows an alert: up to date, the update, unknown version, or the failure reason in words.
  - Alerts go through `LaunchAlertQueue` at launch, like the other launch alerts, and run modally otherwise.
- [ ] **Step 2: Update alert.**
  - Title: "MacCommander %@ is available". Text: "You have %@." Use positional placeholders if one string carries both versions.
  - Buttons: **Open Release Page**, which opens the URL with `NSWorkspace.shared.open`, and **Later**.
  - When `HomebrewInstall.isCask()` is true, add the line "Installed with Homebrew: run brew upgrade --cask maccommander". Run that check off the main actor; a one-time `PathQueries.run` is fine.
- [ ] **Step 3: Menu and Settings.**
  - **MacCommander ▸ Check for Updates…** goes directly under About and is disabled while `isChecking`.
  - In Settings ▸ General, add a toggle "Check for updates automatically", bound to `preferences.preferences.updateCheckEnabled`, and a **Check Now** button that runs the manual check and is disabled while it runs.
  - Use macOS wording for the strings: "Nach Updates suchen …", "Rechercher des mises à jour…", "Sprawdź uaktualnienia…". Check these against system strings on this Mac by grepping, never by dumping a table. Every string goes into all four tables.
- [ ] **Step 4: Launch.** In `AppDelegate.applicationDidFinishLaunching`, start `checkAutomaticallyIfDue` in a `Task`. It must never delay launch.
- [ ] **Step 5: Run** `swift build` and `scripts/test.sh`. Expected: a clean build and all tests pass.
- [ ] **Step 6: Hand check (user).**
  - Run **Check for Updates…** while online and while offline.
  - With a build stamped `0.0.1`, check that the update alert appears and opens the release page.
  - Turn off the toggle, relaunch, and check that nothing appears.
  - Look at the texts in German.
- [ ] **Step 7: Commit** `feat: Check for Updates in the app menu and Settings`
