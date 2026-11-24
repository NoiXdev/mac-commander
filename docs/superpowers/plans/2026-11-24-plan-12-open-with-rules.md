# Open With Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For each file extension, the user picks which app MacCommander opens a file with, inside MacCommander only. Rules are set in a new Settings section "Open With" and used by double-click/⌘↓, archive entries and the Open With menu.

**Architecture:** A Codable `OpenWithRules` value in Core lives in `Preferences`. It normalizes extensions, matches a file by its last extension, and turns a set of URLs into groups per app through an injectable `ApplicationLocating`. `PathQueries.open(_:rules:locator:)` opens those groups off the main actor. The app wires it into the pane model's `opener`, the archive-entry open path and `OpenWithMenu`, and adds a Settings pane.

**Tech Stack:** Swift 6.4, SwiftUI + AppKit, Swift Testing (`scripts/test.sh`), `L10n` tables from plan 11.

**Spec:** `docs/superpowers/specs/2026-11-24-open-with-rules-design.md`

## Global Constraints

- Branch `improvements`. Conventional Commits, no scope (repo style). Commit only once the user has approved committing. Footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- macOS 15+, no new package dependencies, no new entitlements.
- Nothing is written to Launch Services. macOS's own association stays untouched.
- Rules never apply to folders, packages, or pure archives MacCommander browses (`ArchiveFormats.isArchive`). Those keep today's path in `BrowserModel.open`.
- Launch Services and file-system lookups run on the blocking-I/O queue (`PathQueries.run`), never on the main actor.
- Every user-visible string goes through `L10n` with named keys in en, de, fr, pl, following plan 11's rules:
  - the key and English text are single-line literals;
  - Finder wording; German uses the informal du;
  - de puts U+00A0 before "…";
  - fr puts U+00A0 before ; : ? ! and inside « ».

  `SourceKeyTests`, `LocalizationCatalogTests` and `RawStringGuardTests` must pass.
- Tests that compare English text use the `.english` trait. This Mac runs in German.
- User docs (noix-docs) are not touched here. They are updated at the end of the branch.

## Review Focus

- **An extension typed as ".MD " or "md"**: both save one rule `md`. A file `Notes.Md` matches it. Pinned by `normalizesTypedExtensions` and `matchesTheLastExtensionIgnoringCase` (Task 1).
- **A rule whose app was deleted**: the file opens with the system default and no alert appears. Settings shows "Not installed". Pinned by `missingAppFallsBackToTheSystemDefault` (Task 2) and the Task 4 hand check.
- **A mixed selection in the Open With menu** (one `.md` with a rule, one `.txt` without): no "(default)" item. A selection without any rule behaves exactly as today. Pinned by `menuDefaultIsNilForAMixedSelection` and `menuDefaultKeepsTodaysChoiceWithoutRules` (Task 2).
- **A failing open with the system default**: it stays silent, as today, because Launch Services already asks. Only a failing rule-app open is reported. Pinned by `reportsOnlyRuleAppErrors` (Task 2).
- **Preferences written by this build, read by an older one (and vice versa)**: the older one ignores `openWithRules`. An unreadable rule is dropped and the others are kept. Pinned by `unreadableRuleIsDroppedOthersKept` (Task 1).

---

### Task 1: The rules model

**Files:**
- Create: `Sources/MacCommanderCore/Settings/OpenWithRules.swift`
- Modify: `Sources/MacCommanderCore/Settings/Preferences.swift` (new field `openWithRules`, its coding key, lenient decode)
- Test: `Tests/MacCommanderCoreTests/OpenWithRulesTests.swift`, `Tests/MacCommanderCoreTests/PreferencesTests.swift`

**Interfaces:**
- Produces:
  - `public struct OpenWithRule: Codable, Equatable, Sendable { public var bundleIdentifier: String?; public var appPath: String; public var appName: String }`
  - `public struct OpenWithRules: Codable, Equatable, Sendable`, which holds rules keyed by normalized extension:
    - `public init()`
    - `public static func normalizedExtension(_ typed: String) -> String?`
    - `public var extensions: [String]` (sorted)
    - `public subscript(ext: String) -> OpenWithRule? { get }` (key normalized)
    - `public mutating func set(_ rule: OpenWithRule, for ext: String)` (ignores an extension that normalizes to nil)
    - `public mutating func remove(_ ext: String)`
    - `public func rule(for url: URL) -> OpenWithRule?`
  - `Preferences.openWithRules: OpenWithRules` (default empty).

- [ ] **Step 1: Write the failing tests** in `OpenWithRulesTests`:
  - `normalizesTypedExtensions`: `".MD "` → `"md"`, `"md"` → `"md"`, `" .tar"` → `"tar"`, `"..md"` → `nil` (only one dot is dropped, and `".md"` keeps a dot), `""` → `nil`, `"."` → `nil`, `"a.b"` → `nil`, `"a/b"` → `nil`, `"  "` → `nil`.
  - `matchesTheLastExtensionIgnoringCase`: with a rule for `md`, `/x/Notes.Md` matches. With a rule for `gz`, `/x/a.tar.gz` matches. `/x/README` and `/x/.zshrc` match nothing.
  - `setReplacesAnExistingRule`: setting `md` twice keeps the second rule, and `extensions == ["md"]`.
  - `setIgnoresAnInvalidExtension`: `set(rule, for: ".")` leaves the rules empty.
  - `extensionsAreSorted`: after setting `md`, `json` and `c`, `extensions == ["c", "json", "md"]`.
  - `codableRoundTrip`: encode, then decode, gives equal rules.

  In `PreferencesTests`:
  - `openWithRulesDefaultToEmpty`: decoding `{}` gives empty rules.
  - `unreadableRuleIsDroppedOthersKept`: JSON with one valid rule and one rule whose `appPath` is a number decodes to just the valid one.
- [ ] **Step 2: Run** `scripts/test.sh --filter 'OpenWithRulesTests|PreferencesTests'`. Expected: compile failure (no `OpenWithRules`).
- [ ] **Step 3: Implement** `OpenWithRules.swift` and the `Preferences` field.
  - Encode the rules as a JSON object `{ext: rule}`.
  - The lenient decode skips entries that don't decode, and keys that don't normalize, in the same way `knownTags` skips bad entries.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: store per-extension Open With rules`

### Task 2: Resolving and opening with rules

**Files:**
- Create: `Sources/MacCommanderCore/FileSystem/ApplicationLocating.swift`
- Modify:
  - `Sources/MacCommanderCore/Settings/OpenWithRules.swift`
  - `Sources/MacCommanderCore/FileSystem/PathQueries.swift`
  - `Sources/MacCommanderCore/Browser/BrowserModel.swift`
- Test: `Tests/MacCommanderCoreTests/OpenWithRulesTests.swift`, `Tests/MacCommanderCoreTests/BrowserModelTests.swift`

**Interfaces:**
- Consumes: Task 1's `OpenWithRules`, `OpenWithRule`.
- Produces:
  - `public protocol ApplicationLocating: Sendable { func applicationURL(bundleIdentifier: String) -> URL?; func applicationExists(at url: URL) -> Bool; func systemDefaultApplication(for url: URL) -> URL? }`
  - `public struct WorkspaceApplicationLocator: ApplicationLocating`, backed by `NSWorkspace` and `FileManager`.
  - `public static func OpenWithRules.application(for rule: OpenWithRule, locator: some ApplicationLocating) -> URL?`. It tries the bundle id first, then the stored path if it exists, and gives nil when the app is missing.
  - Instance method `OpenWithRules.groups(for urls: [URL], locator: some ApplicationLocating) -> [OpenGroup]`, where `public struct OpenGroup: Equatable, Sendable { public var app: URL?; public var urls: [URL] }` and `app == nil` means the system default. Groups keep the order of each app's first appearance, and URLs keep their order inside a group.
  - `OpenWithRules.menuDefault(for urls: [URL], locator: some ApplicationLocating) -> MenuDefault`, where `public enum MenuDefault: Equatable, Sendable { case system; case app(URL); case none }`:
    - `.system`: no URL has a located rule app. The menu keeps today's logic.
    - `.app(url)`: every URL resolves to the same app (its rule app, else its system default) and at least one has a located rule.
    - `.none`: anything else.
  - `PathQueries.open(_ urls: [URL], rules: OpenWithRules, locator: some ApplicationLocating = WorkspaceApplicationLocator()) async -> (any Error)?`. It builds the groups on the blocking-I/O queue and opens each one: a rule app with `open(_:withApplicationAt:)`, `nil` as today's default open. It returns the first error from a **rule-app** group only. Default-app errors are dropped, as `openWithDefaultApp` does today.
  - `BrowserModel.openWithRules: @MainActor () -> OpenWithRules` (`@ObservationIgnored public var`, default `{ OpenWithRules() }`, like `newFileName`).
  - `BrowserModel.openExternally(_ urls: [URL])`, which hands each URL to `opener`. The archive path in Task 3 calls it.

- [ ] **Step 1: Write the failing tests** with a fake locator in the test file. It holds a bundle-id → URL map, a set of existing paths, and a system-default map.
  - `resolvesByBundleIdentifierFirst`: when the bundle id is found, the result is the locator's URL even if the stored path differs.
  - `fallsBackToTheStoredPath`: an unknown bundle id plus an existing stored path gives the path URL.
  - `missingAppFallsBackToTheSystemDefault`: an unknown bundle id plus a missing path gives `groups(for: [md]) == [OpenGroup(app: nil, urls: [md])]`.
  - `groupsAMixedSelection`: `[a.md, b.txt, c.md]` with a rule only for `md` gives `[OpenGroup(app: typora, urls: [a.md, c.md]), OpenGroup(app: nil, urls: [b.txt])]`.
  - `menuDefaultIsTheRuleAppForAUniformSelection`: `[a.md, c.md]` gives `.app(typora)`.
  - `menuDefaultIsNilForAMixedSelection`: `[a.md, b.txt]`, where `txt`'s system default is TextEdit, gives `.none`.
  - `menuDefaultKeepsTodaysChoiceWithoutRules`: `[b.txt]` with no rules gives `.system`. A rule whose app is missing also gives `.system`.
  - `menuDefaultMatchesWhenRuleAndSystemAgree`: `[a.md, b.txt]`, where `txt`'s system default is Typora, the `md` rule app, gives `.app(typora)`.
  - `reportsOnlyRuleAppErrors`: put the open step behind a test seam (e.g. an internal `opening` closure parameter), so that a failing default open gives `nil` and a failing rule-app open gives that error.
  - In `BrowserModelTests`, `openExternallyHandsEachURLToTheOpener`: two URLs are recorded by the injected `opener` in order.
- [ ] **Step 2: Run** `scripts/test.sh --filter 'OpenWithRulesTests|BrowserModelTests'`. Expected: compile failure.
- [ ] **Step 3: Implement** the four pieces above. Keep `PathQueries.openWithDefaultApp` and `open(_:withApplicationAt:)` unchanged. `BrowserModel.open`'s existing `opener(item.url)` call and the unreadable-archive fallback (`opener(url)`, ~line 821) stay as they are: the app's opener becomes rule-aware in Task 3.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: open files with the app their extension's rule names`

### Task 3: Wire the rules into opening and the Open With menu

**Files:**
- Modify:
  - `Sources/MacCommander/Browser/BrowserWindow.swift` (`paneFactory`)
  - `Sources/MacCommander/Operations/FileActions.swift:202`
  - `Sources/MacCommander/Operations/OpenWithMenu.swift`
  - `Sources/MacCommander/FileList/FileContextMenu.swift:132`

**Interfaces:**
- Consumes: Task 2's `PathQueries.open(_:rules:locator:)`, `OpenWithRules.menuDefault(for:locator:)`, `BrowserModel.openWithRules`, `BrowserModel.openExternally(_:)`.

- [ ] **Step 1: Rule-aware pane opener.**
  - `paneFactory` builds the model with `opener:` set to a closure that calls `PathQueries.open([url], rules: preferences.preferences.openWithRules)` in a `Task`. A non-nil error is shown with `NSAlert(error:)`.
  - It also sets `model.openWithRules = { preferences.preferences.openWithRules }`.
  - The rules are read at open time, so a change in Settings applies at once.
- [ ] **Step 2: Archive entries.** In `FileActions.open(_:model:window:)`, replace `for url in extracted { PathQueries.openWithDefaultApp(url) }` with `model.openExternally(extracted)`.
- [ ] **Step 3: Open With menu.** `OpenWithMenu.make(for:rules:)` takes the rules; `FileContextMenu` passes `model.openWithRules()`. In `applicationsNow`, compute `menuDefault(for:locator:)` once, using the existing samples only for the "others" list:
  - `.system`: today's logic, unchanged.
  - `.app(url)`: that app is the "(default)" item, and the system default joins the others when it opens all items. The existing `operation.openWith.defaultApp` key is reused.
  - `.none`: no "(default)" item.

  The rule app shows as "(default)" even when Launch Services doesn't list it for the type.
- [ ] **Step 4: Run** `swift build` and `scripts/test.sh`. Expected: build clean, no warnings, all pass. No new strings, so the catalogs are unchanged.
- [ ] **Step 5: Hand check (user).** These can't be driven here, so they go to the user's check list:
  - A rule `md → TextEdit`:
    - a double-click opens TextEdit;
    - ⌘↓ on a `.md` inside a zip opens TextEdit;
    - right-click ▸ Open With shows "TextEdit (default)".
  - A mixed selection shows no "(default)" item.
- [ ] **Step 6: Commit** `feat: use Open With rules for double-click, archive entries and the Open With menu`

### Task 4: The "Open With" Settings section

**Files:**
- Create: `Sources/MacCommander/Settings/OpenWithSettings.swift`
- Modify:
  - `Sources/MacCommanderCore/Settings/SettingsSection.swift` (case `openWith` after `view`, title, symbol)
  - `Sources/MacCommander/Settings/SettingsView.swift` (switch)
  - `Sources/MacCommanderCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`
- Test: `Tests/MacCommanderCoreTests/SettingsSectionTests.swift`

**Interfaces:**
- Consumes: Task 1's `OpenWithRules` API, Task 2's `OpenWithRules.application(for:locator:)` and `WorkspaceApplicationLocator`.

- [ ] **Step 1: Update the failing test.**
  - `SettingsSectionTests` expects `[.general, .view, .openWith, .terminal, .shortcuts, .sidebar, .tags, .network]`.
  - `.openWith` has the symbol `doc.badge.gearshape`.
  - Under `.english`, its title is `"Open With"`.
- [ ] **Step 2: Run** `scripts/test.sh --filter SettingsSectionTests`. Expected: FAIL.
- [ ] **Step 3: Implement the section.**
  - **Layout:** a grouped `Form` with a "Rules" section. It lists `extensions` sorted, and each row shows `.ext`, the app icon and name, and a remove button (`minus.circle`, `.help` and `.accessibilityLabel` "Remove").
  - **Missing app:** a rule whose `application(for:locator:)` is nil shows its stored `appName` with `exclamationmark.triangle` and "Not installed". Its help text reads "Files with this extension open with the app macOS assigns until you choose another app."
  - **Changing an app:** clicking a rule's app name picks a new app for that rule.
  - **Add row:** `LabeledContent("Extension")` with `TextField("", text:, prompt: Text("php"))`, 60 pt wide, plus "Choose App…". The button is disabled while `normalizedExtension` is nil.
  - **Footer:** "Rules apply only in MacCommander. Without a rule, files open with the app macOS assigns."
  - **App picker:** an `NSOpenPanel` limited to `.application`, starting at `/Applications`, single selection.
  - **Saving:** the rule stores `Bundle(url:)?.bundleIdentifier`, the app's path, and its display name without `.app`. It writes through `preferences.preferences.openWithRules`.
  - **Strings:** every string gets a `settings.openWith.*` key, and the section title gets `settings.section.openWith`, in all four languages. The title uses Finder's own term for Open With in each language. Check FinderKit's loctable on this Mac: expected "Öffnen mit", "Ouvrir avec", "Otwórz za pomocą", but Finder wins if it differs.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all pass, including the catalog, source-key and raw-string guards.
- [ ] **Step 5: Hand check (user).**
  - Add, change and remove a rule.
  - Check that `.MD` becomes `md` and that `.` keeps the button disabled.
  - Rename an app's bundle away and check that the row shows "Not installed".
  - Check the section in German, French and Polish at the minimum window size.
- [ ] **Step 6: Commit** `feat: Open With section in Settings`
