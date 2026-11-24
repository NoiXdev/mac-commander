# Update check via GitHub releases (short design)

Date: 2026-11-24 · Status: approved in conversation · Branch: `improvements`

**Intent:** MacCommander tells the user when a newer release is out, the way macSCP does. Nothing is downloaded or installed by the app. The user approved this design as proposed.

**Today:** there is no update check. The data page on docs.noix.dev says so ("There is no update check and no telemetry"). Releases are published on GitHub (`NoiXdev/mac-commander`); pre-releases are flagged as such and never reach `/releases/latest`. From the next release on, the app also ships through the Homebrew tap (`brew install --cask maccommander`).

**Prior art:** macSCP's `Sources/macSCPCore/Updates/` (`AppVersion`, `UpdateSchedule`, `ReleaseFetcher`/`GitHubReleaseFetcher`, `UpdateChecker`, `UpdateCheckResult`, `UpdateCheckError`) and `Sources/MacSCPAppKit/UpdateCheckModel.swift`. MacCommander ports these, adapted to its own stores and `L10n`.

## Behavior

- **Automatic check:** at launch, at most once every 24 hours, on by default. The 24 hours count from the last *attempt*, successful or not, so a dead network doesn't retry at every launch. Only a newer release shows an alert. Failures and "up to date" stay silent.
- **Manual check:** **MacCommander ▸ Check for Updates…**, directly under About, disabled while a check runs. Settings ▸ General has a **Check Now** button with the same behavior. A manual check always shows its result: up to date, update available, or why it failed (offline, GitHub's rate limit, an HTTP status, an unreadable answer).
- **Setting:** Settings ▸ General ▸ "Check for updates automatically", on by default.
- **Source:** `GET https://api.github.com/repos/NoiXdev/mac-commander/releases/latest`. It returns finished releases only, never drafts or pre-releases. Headers: `Accept: application/vnd.github+json`, `User-Agent: MacCommander/<version>`, `Accept-Language: en`. No token, no cookies, nothing else is sent.
- **Comparison:** the release tag (`v0.2.0`) against `CFBundleShortVersionString`, by semantic version. If the local version is missing or unreadable, the result is "unknown", never an update claim.
- **Update alert:** "MacCommander 0.2.0 is available. You have 0.1.1." with **Open Release Page** (opens the release's `html_url` in the browser) and **Later**. If MacCommander was installed with Homebrew, a line says so and names the command: `brew upgrade --cask maccommander`.
- **Homebrew detection:** a `maccommander` folder in `/opt/homebrew/Caskroom` or `/usr/local/Caskroom`. *(My call: a cheap, local check with no process launch.)*
- **Strings:** all four languages, with macOS wording: "Nach Updates suchen …", "Rechercher des mises à jour…", "Sprawdź uaktualnienia…". Verify these against the system's own strings.

## Non-goals

- Downloading or installing updates, Sparkle, delta updates.
- Release notes in the app.
- Offering pre-releases.
- Reminding again within 24 hours after "Later".

## Anti-goals

- A check that blocks launch or the main thread.
- An alert at launch when offline.
- Any data sent beyond the request above.

## Left to the builder

File split, type names, the exact alert texts and keys, and how launch alerts queue: use `LaunchAlertQueue`, as the other launch alerts do.

## Docs

`reference/data-and-privacy.md` (network connections) and `reference/settings.md` (General) on docs.noix.dev change with this feature.
