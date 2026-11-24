# Localization (en, de, pl, fr) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every user-visible string goes through named keys with English, German, Polish and French tables and real plurals. A Language picker (default System) sits in Settings ▸ General.

**Architecture:** One `L10n` enum in Core looks strings up in Core's SwiftPM resource bundle (`Resources/{en,de,fr,pl}.lproj`), with English as the fallback at every call site. The build script copies that bundle into the app. Tests read the tables and the sources from disk and prove parity, coverage and that no raw string is left. The language is the app domain's own `AppleLanguages` value, shared with System Settings.

**Tech Stack:** Swift 6.4, SwiftUI + AppKit, Swift Testing (`scripts/test.sh`), `.strings` + `.stringsdict`, app bundle via `scripts/build-app.sh`.

**Spec:** `docs/superpowers/specs/2026-11-24-localization-design.md`

## Global Constraints

- Branch `improvements`. Conventional Commits, no scope (repo style). Commit only once the user has approved committing this plan's work. Footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- macOS 15+, no new package dependencies.
- Languages: exactly `en`, `de`, `fr`, `pl`. `en` is `defaultLocalization`.
- Keys: dotted lower camel case, `<area>.<screen>.<element>` (for example `settings.general.newWindows`). Areas: `app`, `menu`, `browser`, `fileList`, `operation`, `archive`, `convert`, `info`, `preview`, `settings`, `sidebar`, `tags`, `shares`, `error`, `name`.
- Call sites pass the key and the English text as plain single-line string literals, never interpolated: `L10n.string("key", "English")`. Values go in through `L10n.format` or `L10n.plural`. When there is more than one placeholder, they are positional (`%1$@`, `%2$lld`).
- `en.lproj` holds exactly the English text of the call sites.
- Terminology follows Finder and macOS in each language. German uses the informal du.
- Never use `Bundle.module`.
- No string changes its English wording, except the plural fixes ("1 item"). The other exception is the duplicate and archive names in Task 4, where the word now comes from the table.
- User docs (noix-docs) are not touched by this plan. They are updated at the end of the branch.

## Review Focus

- **German Mac, test run:** the whole suite passes with `AppleLanguages = de-DE` (the developer's machine). That covers every test that compares English text.
- **Missing bundle:** launching the bare binary (`swift run`, or an `.app` without the resource bundle) shows English and doesn't crash.
- **System Settings per-app language:** setting MacCommander to Polish there shows "Polski" in the picker after a relaunch. Picking "System" in the app removes that choice, and System Settings then shows the system default again.
- **Relaunch while an operation runs:** "Relaunch MacCommander" during a copy goes through the normal quit confirmation. If the user cancels the quit, the app keeps running and no second copy appears.
- **AppKit menus in German:** the app menu items ("MacCommander beenden", "Einstellungen…"), Edit and Window are German, not only the menus MacCommander adds.

---

### Task 1: `L10n` and the catalogs

**Files:**
- Modify: `Package.swift`: `defaultLocalization: "en"`, and `resources: [.process("Resources")]` on `MacCommanderCore`.
- Create: `Sources/MacCommanderCore/Localization/L10n.swift`
- Create: `Sources/MacCommanderCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings` and `Localizable.stringsdict`
- Create: `Resources/{en,de,fr,pl}.lproj/InfoPlist.strings`, holding the five `NS…UsageDescription` texts
- Modify: `Resources/Info.plist`: `CFBundleDevelopmentRegion` `en`, `CFBundleLocalizations` `[en, de, fr, pl]`
- Modify: `scripts/build-app.sh`: copy `$BIN_PATH/MacCommander_MacCommanderCore.bundle` into `Contents/Resources/`, and `Resources/*.lproj` into `Contents/Resources/`, before signing
- Create: `Sources/MacCommander/App/L10n+SwiftUI.swift`: `extension L10n { static func text(_ key: String, _ english: String) -> Text }`
- Modify: `Sources/MacCommanderCore/Settings/SettingsSection.swift`: its seven titles become the first real keys (`settings.section.general` and so on)
- Test: `Tests/MacCommanderCoreTests/Localization/LocalizationCatalogTests.swift`, `L10nLookupTests.swift`, `SourceKeyTests.swift`, `EnglishTrait.swift`

**Interfaces:**
- Produces:
  - `public enum L10n` with:
    - `static let bundle: Bundle`
    - `@TaskLocal static var localeOverride: String?`
    - `static func string(_ key: String, _ english: String) -> String`
    - `static func format(_ key: String, _ english: String, _ args: any CVarArg...) -> String`
    - `static func plural(_ key: String, count: Int, one: String, other: String, _ args: any CVarArg...) -> String`. The count is always the first format argument and the extra `args` follow (`%1$lld`, `%2$@`). `one` and `other` are the English forms and the fallback.
  - The test trait `.english` (a `TestScoping` trait that runs the test under `L10n.$localeOverride.withValue("en")`).
  - The test helper `LocalizationFiles` (repo root via `#filePath`, the loaded tables per language, all `L10n.*` call sites parsed from `Sources/`).
- Bundle lookup, in this order:
  1. `MacCommander_MacCommanderCore.bundle` in `Bundle.main.bundleURL`.
  2. The same bundle in `Bundle.main.resourceURL`.
  3. Next to the executable.
  4. One level above `Bundle(for:)` of a private class, which is where it sits under `swift test`.

  If none of these exists, fall back to `.main`. That way a missing bundle gives English. With `localeOverride` set, look up through that language's `.lproj` sub-bundle.

- [ ] **Step 1: Write the failing tests**

```swift
// LocalizationCatalogTests
@Test func everyLanguageHasTheSameKeys()          // strings and stringsdict, de/fr/pl vs en
@Test func noValueIsEmpty()
@Test func placeholdersMatchEnglish()             // same multiset of %@ / %lld / %1$@ … per key
@Test func pluralsHaveEachLanguagesCategories()   // en/de/fr: one+other; pl: one+few+many+other
// SourceKeyTests
@Test func everyKeyUsedInSourcesHasItsEnglishText()  // L10n.string/format/text: en value == literal; plural: one/other == en stringsdict
@Test func everyEnglishKeyIsUsed()
// L10nLookupTests
@Test func looksUpTheOverrideLanguage() {
    L10n.$localeOverride.withValue("de") { #expect(SettingsSection.view.title == "Darstellung") }
}
@Test func fallsBackToTheEnglishArgumentForAnUnknownKey() {
    #expect(L10n.string("test.missing", "Fallback") == "Fallback")
}
@Test(.english) func pluralPicksEnglishForms()  // plural(… count: 1 …) == "1 item", count 3 == "3 items"
@Test func polishPluralForms()                  // seed key "test.files": 1 plik, 2 pliki, 5 plików, 22 pliki
```

`SettingsSectionTests.everySectionHasItsOwnSymbolAndTitle` gets `.english`. The `test.*` seed keys are allowed by `everyEnglishKeyIsUsed` only under the `test.` prefix.

- [ ] **Step 2: Run `scripts/test.sh`.** Expected: the new tests fail (`L10n` is not defined).
- [ ] **Step 3: Implement.** Add `L10n`, the package resources, the seven section keys in all four languages and the two `test.*` seed entries. Then add `InfoPlist.strings`, the Info.plist keys and the build-script copy.
- [ ] **Step 4: Run `scripts/test.sh`.** Expected: all pass. Then run `scripts/build-app.sh` and check that `build/MacCommander.app/Contents/Resources/` has the bundle and four `.lproj` folders.
- [ ] **Step 5: Commit** `feat: look up strings in English, German, Polish and French tables`

### Task 2: Language picker

**Files:**
- Create: `Sources/MacCommanderCore/Settings/AppLanguage.swift`: the enum, plus `AppLanguageSetting`
- Create: `Sources/MacCommanderCore/Settings/Relaunch.swift`: `waitAndReopenCommand(pid:bundlePath:) -> String`, after macSCP's `AppRelauncher`, with the path shell-quoted
- Create: `Sources/MacCommander/App/AppRelauncher.swift`: run the command with `/bin/sh -c`, then `NSApp.terminate(nil)`
- Modify: `Sources/MacCommander/Settings/GeneralSettings.swift`: a Language section at the top
- Test: `Tests/MacCommanderCoreTests/AppLanguageTests.swift`, `RelaunchTests.swift`

**Interfaces:**
- Produces:
  - `public enum AppLanguage: String, CaseIterable, Sendable { case system, en, de, fr, pl }`
    - `localeCode: String?`
    - `nativeName: String`: "English", "Deutsch", "Français", "Polski". `system` returns `L10n.string("settings.general.language.system", "System")`.
    - `init(languageIdentifier: String?)`, which maps by prefix (`"de-DE"` → `.de`; `nil` or unknown → `.system`)
  - `@MainActor public struct AppLanguageSetting { init(defaults: UserDefaults = .standard, domain: String); var current: AppLanguage { get nonmutating set } }`. `current` reads `defaults.persistentDomain(forName: domain)?["AppleLanguages"]` (first entry). Setting `.system` removes the key; any other value writes `[code]`.
  - The language in effect at launch is `current` read once, as the process starts (a `static let` in the app target). Don't derive it from `Bundle.main.preferredLocalizations`: a Spanish Mac would report `en` there while the setting is `.system`, and the relaunch button would show for no reason.

- [ ] **Step 1: Write the failing tests:**
  - `mapsIdentifiersByPrefix`: `"de-DE"`, `"pl"`, `"fr-CA"`, `"es"` → `.system`, and `nil`.
  - `systemRemovesTheKeyAndOthersWriteIt`, using a `UserDefaults(suiteName:)` and its domain.
  - `readsAChoiceMadeInSystemSettings`: the domain is preset to `["pl-PL"]` and the result is `.pl`.
  - `nativeNamesAreNotTranslated`: under `de`, `.en.nativeName == "English"`.
  - `relaunchCommandWaitsForThePidAndQuotesThePath`: the path contains a space and a `"`.
- [ ] **Step 2: Run `scripts/test.sh`.** Expected: the new tests fail.
- [ ] **Step 3: Implement the types.** Then the UI: a `Picker` over `AppLanguage.allCases` showing `nativeName`, and the footer "Takes effect after a relaunch.". "Relaunch MacCommander" is shown while `current` differs from the language read at launch. Every new text gets a key in all four languages.
- [ ] **Step 4: Run `scripts/test.sh`, then `scripts/build-app.sh`.** Expected: all pass. Open the app and pick Deutsch, then Relaunch: the section titles are German. Pick System, then Relaunch: back to the system language.
- [ ] **Step 5: Commit** `feat: choose the app's language in Settings`

### Task 3: Core strings

**Files:**
- Modify: every Core file with `String(localized:`, which is 114 calls in `Archives`, `Browser`, `Convert`, `FileSystem`, `Model`, `Operations`, `Preview`, `Settings`, `Shares` and `Tags`. Add the matching entries to all four tables.
- Modify: `Sources/MacCommanderCore/Shares/NetFSMounter.swift:55-57,108`: the app's own texts (`"No mount point"`, `"Error %lld (%@)"`) get keys. Raw `strerror()`, bsdtar and ffmpeg text stays raw, but only ever as the `%@` detail of a keyed sentence.
- Modify, adding `.english` to the suites that compare English text: `PaneTransferTests`, `TagEditorTests`, `TagCatalogTests`, `FileOperationCenterTests`, `ItemRenamerTests`, `ShareStoreTests`, `ArchiveCatalogTests`, and any other suite that fails on a German Mac.

**Interfaces:**
- Consumes: `L10n` and `.english` (Task 1).
- Produces: no new API. Count strings use `L10n.plural`, for example `operation.copy.title` for "Copying %1$lld items to “%2$@”", with English `one` "Copying 1 item to “%2$@”".

- [ ] **Step 1: Write the failing tests:**
  - `FileOperationCenterTests.titleUsesTheSingularForOneItem`: copying one item is titled "Copying 1 item to “X”".
  - `PaneTransferTests.promptUsesThePolishPlural`: under `pl`, the prompt for 5 items has the `many` form.
  - `NetFSMounterTests.ownErrorTextIsTranslated` (or the nearest existing suite): under `de`, the no-mount-point error is not English.
- [ ] **Step 2: Run `scripts/test.sh`.** Expected: these fail.
- [ ] **Step 3: Convert** each call, writing its translations into de, fr and pl. Merge the "1 audio track" / "\(count) audio tracks" pair into one plural (it lives in the app; leave it for Task 7 if that is cleaner).
- [ ] **Step 4: Run `scripts/test.sh`.** Expected: everything passes, catalog and source-key tests included. This Mac runs `de-DE`, so a green run here is the German-Mac proof from the Review Focus.
- [ ] **Step 5: Commit** `feat: translate the file-operation, archive, convert and share messages`

### Task 4: Generated names

**Files:**
- Modify: `Sources/MacCommanderCore/FileSystem/ItemCreator.swift`: the folder base becomes `name.newFolder` ("untitled folder"; "Neuer Ordner", "Nowy folder", "nouveau dossier"), and the new-file default becomes `name.newFile` ("untitled.txt"; "Neue Datei.txt", …)
- Modify: `Sources/MacCommanderCore/FileSystem/NameGenerator.swift`: `copyName(for:isDirectory:in:copyWord:fileManager:)`. The default for `copyWord` is `L10n.string("name.copySuffix", "copy")` ("Kopie", "kopia", "copie"). The regex recognises both `copyWord` and `"copy"` when it continues the numbering, and always writes `copyWord`.
- Modify: `Sources/MacCommanderCore/Operations/Compressor.swift:41,80`: `name.archive` "Archive" ("Archiv", "Archiwum", "Archive").
- Modify: `Sources/MacCommanderCore/Settings/Preferences.swift`:
  - `newFileName` defaults to `""`, which means the built-in name.
  - Lenient decode maps a stored `"untitled.txt"` to `""`.
  - `effectiveNewFileName` returns the localized `name.newFile` when the value is empty or invalid.
- Modify: `Sources/MacCommander/Settings/GeneralSettings.swift`: the text field's prompt shows the localized default, and the invalid-name warning names it with `L10n.format`.
- Test: `NameGeneratorTests`, `ItemCreatorTests`, `CompressorTests`, `PreferencesTests`

- [ ] **Step 1: Write the failing tests:**
  - `copyNameUsesTheLanguagesWord`: under `de`, "Bericht.txt" becomes "Bericht Kopie.txt".
  - `copyNameContinuesAnEnglishCopyAfterASwitch`: under `de`, "report copy.txt" becomes "report Kopie 2.txt".
  - `newFolderUsesTheLanguagesName`: under `de`, the folder is "Neuer Ordner".
  - `oldDefaultFileNameDecodesAsBuiltIn`: `"untitled.txt"` decodes to `""`, and under `.english` `effectiveNewFileName == "untitled.txt"`.
  - `customFileNameIsKept`.
- [ ] **Step 2: Run `scripts/test.sh`.** Expected: these fail. Existing tests that expect "untitled folder", " copy" or "Archive" get `.english`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run `scripts/test.sh`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat: name new folders, copies and archives in the app's language`

### Task 5: Settings, Sidebar, Tags and Shares

**Files:**
- Modify: every file with `String(localized:` under `Sources/MacCommander/Settings`, `Sidebar`, `Tags` and `Shares` (about 134 calls, including the bare literals in `ConnectToServerSheet.swift`). Add the matching table entries in all four languages. Tag counts ("The tag is renamed on %lld files.", "It is removed from %lld files.") become plurals.

**Interfaces:**
- Consumes: `L10n`, `L10n.text` (Task 1).

- [ ] **Step 1: Run `SourceKeyTests` as a baseline.** Expected: it passes. The task's proof is that it still passes with every converted call checked against the tables.
- [ ] **Step 2: Convert** the files and write the translations. For every plural, check the pl `few` and `many` forms by hand (2, 5, 22).
- [ ] **Step 3: Run `scripts/test.sh`.** Expected: all pass. `grep -rn 'String(localized:' Sources/MacCommander/{Settings,Sidebar,Tags,Shares}` prints nothing.
- [ ] **Step 4: Build, switch to Deutsch, relaunch, and look at every Settings section, the sidebar, the tag sheets and Connect to Server.** Expected: no English and no raw key. Long German labels aren't clipped at the window's minimum size.
- [ ] **Step 5: Commit** `feat: translate Settings, the sidebar, tags and network shares`

### Task 6: Menus, browser and file list

**Files:**
- Modify: `Sources/MacCommander/App` (19 calls plus the 22 bare literals in `BrowserCommands.swift`), `Browser` (17 calls plus `GoToFolderSheet.swift`) and `FileList` (48 calls). Add the matching table entries in all four languages. "Quick Look %lld items" and "Compress %lld Items" become plurals.

- [ ] **Step 1: Run `SourceKeyTests` as a baseline.** Expected: it passes.
- [ ] **Step 2: Convert** the files and write the translations. Where Finder has the same menu or command, use Finder's wording in that language: "Go" → "Gehe zu", "Go to Folder…" → "Gehe zum Ordner …", "Get Info" → "Informationen".
- [ ] **Step 3: Run `scripts/test.sh`.** Expected: all pass, and no `String(localized:` is left in these three folders.
- [ ] **Step 4: Build and check in German:** every menu, the context menu on one and on several files, Go to Folder, and the column headers.
- [ ] **Step 5: Commit** `feat: translate the menus, the browser and the file list`

### Task 7: Operations, archives, Info and preview

**Files:**
- Modify: `Sources/MacCommander/Operations` (43 calls), `Archives` (5), `Info` (13) and `Preview` (9). Add the matching table entries in all four languages.
  - Plurals: "%1$lld of %2$lld files", "%lld unreadable sectors…", the audio-track pair, "%lld items couldn’t be processed.", and "%lld items" in Info and Preview.
  - "%1$lld of %2$lld" stays a format, not a plural.

- [ ] **Step 1: Run `SourceKeyTests` as a baseline.** Expected: it passes.
- [ ] **Step 2: Convert** the files and write the translations.
- [ ] **Step 3: Run `scripts/test.sh`.** Expected: all pass, and `grep -rn 'String(localized:' Sources` prints nothing.
- [ ] **Step 4: Build and check in German:** a copy with progress, a failed extract (the raw detail inside the German sentence), Get Info on several items, and Quick Look.
- [ ] **Step 5: Commit** `feat: translate file operations, archives, Get Info and the preview`

### Task 8: Guard against raw strings

**Files:**
- Create: `Tests/MacCommanderCoreTests/Localization/RawStringGuardTests.swift`

- [ ] **Step 1: Write the tests:**
  - `noStringLocalizedLeft`: no `String(localized:` in `Sources/`.
  - `noBareUILiterals`: no `Text("`, `Button("`, `Toggle("`, `Label("`, `Section("`, `Picker("`, `Menu("`, `CommandMenu("`, `LabeledContent("`, `TextField("`, `SecureField("`, `.help("`, `.navigationTitle("`, `.alert("` or `.confirmationDialog("` followed by a literal with a letter in it. `NSMenuItem(title: "`, `messageText = "`, `informativeText = "` and `addButton(withTitle: "` are banned too.
  - An `allowList: [(file: String, literal: String, reason: String)]` lets exceptions through. It starts with the four native language names in `AppLanguage.swift`. A test fails when an allow-list entry no longer matches anything.
- [ ] **Step 2: Run `scripts/test.sh`.** Expected: these pass, because Tasks 3, 5, 6 and 7 removed everything. Prove the guard bites: add `Text("Probe")` to a scratch line, see `noBareUILiterals` fail, then remove the line.
- [ ] **Step 3: Full run-through in the built app**, in pl and fr as well as de. Note clipped labels and fix them with layout, not shorter translations.
- [ ] **Step 4: Run `scripts/test.sh`.** Expected: all pass.
- [ ] **Step 5: Commit** `test: fail on user-visible text that skips the tables`
