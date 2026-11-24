# Open With rules: a per-extension app, inside MacCommander only (design)

Date: 2026-11-24 · Status: draft for approval · Branch: `improvements`

## Intent

The user picks, per file extension, which app MacCommander opens a file with, e.g. `.md → Typora`. The rule applies **only inside MacCommander**. macOS's own association (Finder's Get Info ▸ "Change All…") stays untouched, so the Finder and every other app keep opening the file as before. The Settings section follows macSCP's "Open with" section so the two apps look alike. The user approved the design as sketched in the conversation.

## Today

- Double-click and ⌘↓ go through `BrowserModel.open(_:)` → `opener(item.url)`. The default `opener` is `PathQueries.openWithDefaultApp`, which calls `NSWorkspace.open` on the blocking-I/O queue. `BrowserWindow` builds the model without injecting an opener.
- Opening a file inside an archive (`FileActions.open(_:model:window:)`) extracts it through `ArchivePreviewCache` and calls `PathQueries.openWithDefaultApp` per extracted copy.
- Right-click ▸ Open With (`OpenWithMenu`) asks Launch Services off the main actor. It shows the first item's system default as "%@ (default)", then the other apps that open every selected item, then "Other…".
- `PathQueries.open(_:withApplicationAt:)` already opens a set of URLs with a given app and returns the error.
- Preferences live in `Preferences` (Codable, lenient decoding: a bad field falls back to its default) behind `PreferencesStore`. Settings sections are the `SettingsSection` enum in Core (title + SF Symbol per case).
- macSCP (`~/_dev/macSCP/Sources/MacSCPAppKit/SettingsView.swift`, `OpenWithSettingsTab`) has a "Default editor" plus per-extension rules, stored as app paths. It normalizes extensions (trim, one leading dot dropped, lowercased) and gates the "Choose app…" button on the normalized value.

## Goals

1. A new Settings section **"Open With"** lists the rules (extension, app name with icon, a remove button) and has an "add" row: an extension field and a "Choose App…" button that opens an app picker.
2. A rule decides which app opens a file with that extension when the user opens it in MacCommander:
   - double-click and ⌘↓ (`BrowserModel.open`), including files in search results;
   - files opened from inside an archive, after extraction.
3. Right-click ▸ Open With shows the rule's app at the top, marked "(default)", so the menu tells the truth about what a double-click does. The system default then appears in the list with the other apps.
4. With several selected files opened at once, each file goes to the app of its own extension (rule or system).
5. All new text in en, de, fr, pl through `L10n`, following plan 11's rules (named keys, Finder wording, no raw strings; `RawStringGuardTests` and `SourceKeyTests` must pass).

## Non-goals

- Changing macOS's association. Nothing is written to Launch Services.
- A global "default editor" for every file (macSCP has one). Locally it would override every system association; left out on purpose.
- Rules by content type (UTI), by folder, or by name pattern. Extension only.
- Folders and packages (`.app`, `.rtfd`, …): they navigate or open as today; rules never apply to them.
- Pure archives that MacCommander browses as folders (`ArchiveFormats.isArchive`): opening them still navigates into the archive. A rule for `zip` would only matter for the Open With menu.
- Get Info's "Open with" area, Quick Look, "Open in Terminal", Dock drops: unchanged.
- Import/export of rules, syncing across Macs.

## Anti-goals

- A rule silently does nothing. If its app is gone, the user can see that in Settings.
- Opening becomes slower or blocks the main thread. Rule lookup is a dictionary read; resolving the app happens with the open, off the main actor, like today.
- Finder or other apps change behavior.

## Decided

### Matching

- The key is the file's **last** path extension, lowercased: `archiv.tar.gz` → `gz`, as the Finder does. A file without an extension never matches.
- Extensions typed in Settings are normalized like macSCP: trim whitespace, drop **one** leading dot, lowercase. A value that normalizes to empty is not accepted ("Choose App…" stays disabled). An extension containing a dot or a slash after normalization is not accepted either.
- One rule per extension. Adding a rule for an extension that already has one replaces it.

### Storing the app

- A rule stores the app's **bundle identifier** (resolved through `NSWorkspace.urlForApplication(withBundleIdentifier:)` when used), so it survives the app being moved or updated. *(My call, over macSCP's path.)*
- It also stores the app's last known path and display name, so Settings can show a name for an app that's no longer installed, and so an app without a bundle identifier (rare) can still be used by path.
- Lives in `Preferences` as a new field (e.g. `openWithRules`), decoded leniently: an unreadable rule is dropped, the others kept. An older build ignores the field.

### When the app is missing

- At open time: if the rule's app can't be found (neither by bundle id nor by stored path), MacCommander opens the file with the system default, as if there were no rule. No alert.
- In Settings: such a rule shows the stored name with a warning sign and "Not installed" (help text explains that files open with the system default meanwhile). The user can remove it or pick a new app for it.

### Opening

- `BrowserModel.open` keeps its `opener` seam. The app injects an opener that consults the rules, or Core's `PathQueries` gains a rule-aware entry point. The builder decides; the rule lookup itself (normalize, match, resolve) lives in Core and is unit-tested there.
- Several URLs: grouped by resolved app; URLs without a rule open with their system default, as today. Errors from a rule-app open are shown like Open With errors today (`NSAlert(error:)`).
- Archive entries: the extracted copy has the entry's name, so the same lookup applies.
- *(My call, after the builder check.)* Core gets a rule-aware batch entry point that groups URLs by resolved app; the per-URL `opener` becomes a thin wrapper around it. `BrowserModel` has no window, so the error alert for a failed rule-app open is shown by the opener the app injects. `BrowserModel`'s fallback open of an unreadable archive goes through the same rule-aware path.

### Open With menu

- When every selected file resolves to the same rule app, that app is the menu's "(default)" item. The system default, if different, joins the other apps in the list. When the files resolve to different apps (mixed rules), the menu shows no "(default)" item, only the apps that open all files, sorted, then "Other…". That matches today's behavior for a mixed selection.
- A rule app that can't open the file type according to Launch Services is still shown as "(default)": the user chose it on purpose.

### Settings section

- New `SettingsSection` case `openWith`, placed after View: General, View, **Open With**, Terminal, Shortcuts, Sidebar, Tags, Network. SF Symbol `doc.badge.gearshape` (as macSCP). Title "Open With", Finder's wording in each language ("Öffnen mit", "Ouvrir avec", "Otwórz za pomocą"; verify against Finder).
- Layout as macSCP's, grouped form:

  ```
  Open With
  ┌───────────────────────────────────────────┐
  │ .md     [icon] Typora                  ⊖  │
  │ .json   [icon] Visual Studio Code      ⊖  │
  │ .log    ⚠ Console — Not installed       ⊖  │
  │ Extension [ php ]    [Choose App…]        │
  └───────────────────────────────────────────┘
  Rules apply only in MacCommander. Without a rule, files open
  with the app macOS assigns.
  ```

- Rules are listed sorted by extension. The extension field uses an empty title and a `prompt:` placeholder (macSCP's fix: a grouped form shows a `TextField` title as a permanent label).
- "Choose App…" opens an app picker starting in `/Applications` (an `NSOpenPanel` limited to applications; `.fileImporter` can't set the start folder). Clicking an existing rule's app lets the user pick a new app for it.
- Changes apply at once to every open window, as all other settings do.

## Left to the builder

- Where the rule-aware open lives (injected opener vs a `PathQueries` entry point) and how the app is resolved off the main actor.
- The exact `Preferences` field shape and the rule type's name.
- Keys under `settings.openWith.*` and `operation.openWith.*`.
- Whether the Settings list shows app icons (nice, not required).
- Test split. Required at least: normalization (dot, case, whitespace, empty, `"."`, `"a.b"`), last-extension matching, lenient decoding, missing-app fallback, grouping of a mixed selection, the menu's "(default)" choice for single, uniform and mixed selections.

## Risks

- **Launch Services latency on network volumes:** resolving the app must stay on the blocking-I/O queue, as `PathQueries` does today.
- **Sandbox/hardened runtime:** opening a file with a specific app uses the same `NSWorkspace.open(_:withApplicationAt:)` the Open With menu already uses; no new entitlement.
- **Hand check:** the app picker, the "Not installed" row and the menu's "(default)" can only be confirmed in the running app.
