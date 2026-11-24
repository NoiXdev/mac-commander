# Localization: English, German, Polish, French (design)

Date: 2026-11-24 · Status: draft for approval · Branch: `improvements`

## Intent

MacCommander gets four UI languages: English, German, Polish and French, the same set as macSCP. A "Language" picker in Settings ▸ General lets the user override the system language. The default is "System", so a German Mac shows German without the user doing anything. The two apps are meant to look and behave alike, so the setup copies macSCP's: named keys, `.lproj` tables, a launch-time `AppleLanguages` override and a relaunch button.

## Today

- About 400 user-visible strings, all English: 288 `String(localized: "…")` calls in the app target (39 files), 114 in Core (20 files), and 27 bare SwiftUI literals such as `Button("New Folder")` in 3 files (`BrowserCommands.swift`, `GoToFolderSheet.swift`, `ConnectToServerSheet.swift`).
- There are no `.lproj`, `.strings` or `.xcstrings` files, no `defaultLocalization` in `Package.swift`, and no `CFBundleLocalizations` in `Resources/Info.plist`.
- `scripts/build-app.sh` builds the `.app` by hand. It copies the binary, `Info.plist`, the notices and the icon. SwiftPM resource bundles are not copied today.
- About 25 strings carry a count: "\(count) items", "Copying \(n) items to “\(folder)”", "The tag is renamed on \(count) files." and so on. In English they read "1 items" today. Polish needs three plural forms (1 plik, 2 pliki, 5 plików).
- Five permission texts in `Info.plist` (`NS…UsageDescription`), all the same English sentence.
- Default names: `untitled folder` (`ItemCreator`) and `untitled.txt` (`Preferences.defaultNewFileName`, also stored in the user's preferences).
- Only one test target, `MacCommanderCoreTests`. It imports Core. The app target is an executable and can't be imported.
- The developer's Mac runs in German (`AppleLanguages = de-DE`). Once tables exist, any test that compares English text would see German unless the language is pinned.

## Goals

1. Every user-visible string in both targets goes through named keys and is translated into de, pl and fr. This covers menus, buttons, labels, alerts, errors, progress text, accessibility labels and help tags.
2. Count strings use real plural rules in all four languages. That also fixes the English "1 items".
3. Settings ▸ General gets a "Language" picker: System, English, Deutsch, Polski, Français. The default is System. A change takes effect after a relaunch, and the app offers a relaunch button.
4. The menus macOS provides (the app menu, Edit, Window, Help, "Quit MacCommander", the Services menu) and the permission prompts follow the same language.
5. Tests prove that nothing is missing: every key used in the sources exists in all four tables, all four tables have the same keys and the same placeholders, and no raw `String(localized:` or bare UI literal is left.

## Non-goals

- Translating the user documentation on docs.noix.dev, the README or the release notes. They stay English.
- Right-to-left layout and languages beyond the four.
- Switching the language live without a relaunch. macSCP doesn't either: the bundle caches its tables.
- Translating what macOS returns: `error.localizedDescription`, app and volume names, file names. macOS already gives those in the system language.
- *(My call, after the builder check.)* Translating the raw output of external tools: bsdtar and ffmpeg stderr, and `strerror()` text. These stay as they come, always as a detail inside a translated sentence such as "“%@” couldn’t be extracted: %@", never on their own. Where the app writes such text itself, it gets a key, for example `"No mount point"` and `"Error \(status) (\(name))"` in `NetFSMounter`. The Archives, Convert and Network tasks check that no raw message reaches the UI without its sentence.

## Anti-goals

- A string that shows its key (`browser.menu.newFolder`) or English in the middle of a German screen. The tests must catch both.
- Breaking the existing tests on a German Mac. Tests that compare English text must keep passing whatever the system language is.
- A crash when the resource bundle is missing, for example in a stripped launch. The app falls back to English, as macSCP's `L10n` does.

## Approaches

Chosen by the user: **B, named keys as in macSCP.**

- **A: English text as the key.** The `String(localized:)` calls stay, and a String Catalog is compiled into the bundle. This is the smallest change. Not chosen: it differs from macSCP, and changing an English sentence silently drops its translations.
- **B: named keys (chosen).** `L10n.string("settings.general.newWindows", "New windows open:")` with `Resources/{en,de,fr,pl}.lproj/Localizable.strings`, plus `.stringsdict` for plurals. Every call site changes. In return, the setup matches macSCP, the wording can change without losing translations, and parity can be tested key by key.

## Decided

### Lookup: one `L10n` in Core

- `public enum L10n` in `MacCommanderCore`, used by both targets. Its API is:
  - `string(_ key: String, _ english: String) -> String`
  - `format(_ key: String, _ english: String, _ args: CVarArg...) -> String` for placeholders
  - `plural(_ key: String, count: Int, …)` for counts, backed by `.stringsdict`
  - a SwiftUI convenience such as `text(_:_:) -> Text`

  The exact plural signature is left to the builder. The English text at every call site is both the fallback and the source for `en.lproj`.
- Catalogs live in **one** place: `Sources/MacCommanderCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings` and `Localizable.stringsdict`. `Package.swift` gets `defaultLocalization: "en"` and `resources: [.process("Resources")]` on Core. One catalog is simpler than macSCP's two, and the app target already depends on Core.
- The bundle is found the way macSCP's `L10n.bundle` does it: look for `MacCommander_MacCommanderCore.bundle` next to the executable, in `Bundle.main.resourceURL` and next to the test bundle, and fall back to `.main`. Never use `Bundle.module`, which calls `fatalError` when the bundle is missing.
- `@TaskLocal static var localeOverride: String?` resolves every lookup against one language. Tests use it, the app never sets it. It is how tests stay English on a German Mac and how each language can be checked.
- `scripts/build-app.sh` copies the Core resource bundle into `Contents/Resources/` before signing.

### Keys

- Dotted, lower camel case, grouped by area, then by screen, then by element: `settings.general.newWindows`, `menu.file.newFolder`, `operation.copy.progress`, `error.extract.failed`. The builder sets the area list in the plan from the source folders: Browser, FileList, Operations, Settings, Sidebar, Tags, Network, Preview, Info, Convert, App/menus.
- Placeholders are positional (`%1$@`, `%2$lld`) whenever there is more than one, so a translation can reorder them.
- `en.lproj` holds exactly the English text from the call sites. A test checks that the two match, so they can't drift apart.

### Plurals

- Every count string becomes a `.stringsdict` entry with `one` and `other` for en, de and fr, and `one`, `few`, `many` and `other` for pl. In French, 0 and 1 are both `one`.
- English gets proper singular forms ("1 item", "1 file"). This is a visible change in English and it is intended.
- `“\(name)” has 1 audio track.` and its counted sibling merge into one plural entry.

### Language picker

- `public enum AppLanguage: String, Codable, CaseIterable, Sendable { case system, en, de, fr, pl }` in Core, with `localeCode: String?` (`nil` for system), as in macSCP.
- *(My call, after the builder check.)* **The picker's only store is `AppleLanguages` in the app's own defaults domain.** There is no separate field in `Preferences`. Once `CFBundleLocalizations` exists, macOS offers a per-app language under System Settings ▸ General ▸ Language & Region ▸ Applications. That setting writes the same key. macSCP's approach stores its own field and clears the key at every launch under "System", which would silently wipe the user's System Settings choice. Using one store avoids that:
  - The picker reads the first entry of the app domain's `AppleLanguages` (`persistentDomain(forName:)`, not the global value) and maps it by language prefix: `de-DE` → `.de`. A missing key, or a language we don't ship, shows `.system`.
  - Choosing a language writes `[code]`, and choosing System removes the key. Nothing is written at launch.
  - A choice made in System Settings and one made in the picker are therefore the same setting, in both directions.
- The setting as read at launch is kept as `launchLanguage` for the relaunch button. It is not derived from `Bundle.main.preferredLocalizations`: on a Mac whose language isn't shipped, that reports `en` while the setting is System.
- Settings ▸ General, at the top: a "Language" picker. Its rows are "System" (translated) and then the language names in their own language: English, Deutsch, Polski, Français. A footer reads "Takes effect after a relaunch." While the selection differs from `launchLanguage`, a "Relaunch MacCommander" button appears. It starts a new instance of the app and quits this one. Windows are not restored beyond what the app already restores at launch.

### What macOS shows

- `Info.plist` gets `CFBundleDevelopmentRegion = en` and `CFBundleLocalizations = [en, de, fr, pl]`.
- `build-app.sh` writes `Contents/Resources/{en,de,fr,pl}.lproj/InfoPlist.strings` with the translated permission text. Its source is `Resources/{lang}.lproj/InfoPlist.strings` in the repo. Because the main bundle then has these `.lproj` folders, AppKit's own menu items follow the chosen language too.

### Default names

- `untitled folder` and the default for new files follow the language: "Neuer Ordner" and "Neue Datei.txt" in German, with Finder's wording in each language. A name the user typed in Settings stays as typed. Only the built-in default changes. How "no custom name" is stored is the builder's call. One option is to store `nil` instead of `untitled.txt` and migrate the old value.
- *(My call, after the builder check.)* The other names the app generates follow Finder too:
  - The duplicate pattern "%@ copy" (`NameGenerator.copyName`), with the separator Finder uses in each language: "Bericht Kopie.txt" in German, "raport-kopia.txt" in Polish.
  - `Archive.zip` for a multi-item compress: "Archiv.zip".
  - `NameGenerator` takes the pattern from its caller. When counting on, it recognises both the current language's pattern and the English " copy", so "report copy.txt" made before a language switch still numbers on.

### Terminology

- Follow Finder and macOS in each language: Papierkorb / Kosz / Corbeille, Informationen / Informacje / Lire les informations, and so on. Use the informal du in German, as macOS does. Polish and French use macOS's own neutral or polite UI register.
- The builder writes the translations. A native speaker should review pl and fr before release. The design doesn't block on that review.

### Tests (Core test target, reading files from disk by `#filePath`)

- **Parity:** all four `Localizable.strings` have the same keys, every value is non-empty, and every value has the same placeholders in kind and count. The same holds for `.stringsdict`, plus the plural categories each language needs.
- **Source scan:** every `L10n.*("key", "English")` in `Sources/` has its key in `en.lproj` with exactly that English text. Every key in `en.lproj` is used somewhere. No `String(localized:` is left, and no bare literal in `Text("…")`, `Button("…")`, `Toggle("…")`, `Label("…")`, `Section("…")`, `CommandMenu("…")`, `.help("…")` and similar. Strings that must stay literal (symbol names, "English", "Deutsch" and so on) go on an explicit allow-list with a reason.
- **Lookup:** under `localeOverride` "de", "pl" and "fr", a sample key from Core returns the translation, and a plural returns the right form for 1, 2, 5 and 22 in Polish.
- **Pinned English:** existing tests that compare English text run under `localeOverride = "en"`, for example via a shared trait or helper. The suite passes on a German Mac.
- **`AppLanguage`:** codes, lenient decoding and the default `.system`.

## Left to the builder

- The exact key for each string, the area prefixes and the order of entries in the files.
- The exact plural API and whether `format` and `plural` share one entry point.
- How to make the conversion of about 430 call sites safe. One option is a throwaway script that emits keys and the English table and is then reviewed by hand. Whatever is used, the tests above are the proof.
- How the tests are split into suites.
- How "Relaunch" starts the new instance (`NSWorkspace.openApplication` with `createsNewApplicationInstance`, or `open -n`), as long as no second copy is left running.

## Risks

- **Size.** Touching about 60 files at once makes for a large diff. The plan should split it by area so each task builds and passes on its own.
- **Missed strings** in AppKit code (`NSAlert`, `NSMenuItem`) that the literal scan doesn't see because they use variables. The source scan covers `String(localized:`. A final pass through the running app in German is still needed.
- **Translation quality** in pl and fr. Short sentences and Finder terms keep it predictable. A native review is recommended.
