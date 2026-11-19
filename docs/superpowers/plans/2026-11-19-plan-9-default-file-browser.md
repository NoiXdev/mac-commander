# Default File Browser and Global Hotkey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let other apps' "Show in Finder" and folder opens (Dock drop, `open -a`, Open With) land in new MacCommander windows, and bring MacCommander to the front with a user-chosen global hotkey.

**Architecture:**
- **Core:** three small, testable pieces:
  - `FileViewerSetting`: reads and writes the global `NSFileViewer` value through an injectable store.
  - `OpenRequest`: groups incoming URLs into windows.
  - `GlobalShortcut`: a value type plus Carbon modifier mapping, stored in `Preferences`.
- **App target:**
  - Incoming opens: `application(_:open:)` in `AppDelegate`.
  - Windows: an `OpenRequestRouter` that new `BrowserWindow`s take their start folder and selection from, and that opens windows through a captured `openWindow`.
  - Hotkey: a Carbon `HotKeyCenter`.
  - Settings: rows in `GeneralSettings`.

**Tech Stack:** Swift 6, SwiftPM (Command Line Tools only), SwiftUI and AppKit, Carbon (`RegisterEventHotKey`), CoreFoundation preferences, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-19-default-file-browser-design.md`

## Global Constraints

- **Toolchain:** Swift 6 with SwiftPM and Command Line Tools only. Run tests with `scripts/test.sh` and build the app with `scripts/build-app.sh`. Work happens on `main`. No new third-party dependencies.
- **Bundle ids:** the app is `dev.noix.MacCommander`; the Finder is `com.apple.finder`.
- **Global value:** the `NSFileViewer` key in the any-application domain, current user, any host (`defaults write -g NSFileViewer dev.noix.MacCommander`).
- **Tests never change the real global `NSFileViewer`** and never register a real global hotkey. Both go through injectable seams.
- **Never launch or quit the app while the user's MacCommander instance is running** (check with `pgrep -x MacCommander`). The manual checks are for the user.
- **Copy, verbatim:**
  - "Use MacCommander for “Show in Finder”"
  - "Global hotkey"
  - "This shortcut is already in use"
- **Modifier rule:** a shortcut needs at least one of ⌘, ⌥ or ⌃. Shift alone doesn't count.
- **New windows:** every incoming open request gets a new window and never reuses the front window. A single folder shows its contents. Everything else is grouped by parent folder, one window per parent, with those items selected.
- **Packages count as files:** `.app` and other packages are selected in their parent, not opened.
- **Our own "Reveal in Finder" must keep going to the Finder** while the toggle is on.

## Review Focus

1. **Cold launch via "Show in Finder":** with MacCommander not running, a reveal must end with exactly one window at the target folder with the item selected. There must be no extra home window next to it. Covered by the Task 4 router rules and manual check M2.
2. **Another file viewer already set:** while another app such as Path Finder owns `NSFileViewer`, the toggle shows off. Turning it off must never delete that other app's value. Test in Task 1.
3. **Package reveal:** revealing `Safari.app` must open `/Applications` with Safari selected, not the inside of the bundle. Test in Task 2.
4. **Missing or unreachable paths:** an item that isn't there must not crash or produce a window at `/`. It is treated as a file in its parent. Test in Task 2.
5. **Shortcut stored by a newer or older version:** an unreadable `globalShortcut` value decodes as nil (off), and the other preferences survive. Test in Task 3.

---

### Task 1: `FileViewerSetting` (Core)

**Files:**
- Create: `Sources/MacCommanderCore/Settings/FileViewerSetting.swift`
- Test: `Tests/MacCommanderCoreTests/FileViewerSettingTests.swift`

**Interfaces:**
- Produces:
  - `public protocol GlobalDefaultsStore: Sendable { func string(forKey key: String) -> String?; func set(_ value: String?, forKey key: String) }`. A nil value removes the key.
  - `public struct CFGlobalDefaultsStore: GlobalDefaultsStore`: the real store, using `CFPreferencesCopyValue` and `CFPreferencesSetValue` with `kCFPreferencesAnyApplication`, `kCFPreferencesCurrentUser` and `kCFPreferencesAnyHost`, then `CFPreferencesSynchronize`.
  - `public struct FileViewerSetting`:
    - `init(bundleIdentifier: String, store: GlobalDefaultsStore)`
    - `public static let key = "NSFileViewer"`
    - `var isEnabled: Bool`: true when the stored value equals `bundleIdentifier`, compared case-insensitively.
    - `func setEnabled(_ on: Bool)`: on writes `bundleIdentifier`. Off removes the key only while it is ours, and leaves any other app's value alone.

- [ ] **Step 1: Write the failing tests.** Use a `final class FakeStore: GlobalDefaultsStore, @unchecked Sendable` with a dictionary.
  - `enableWritesBundleID`: `setEnabled(true)` makes `store.string(forKey: "NSFileViewer") == "dev.noix.MacCommander"` and `isEnabled == true`.
  - `disableRemovesOwnValue`: after enabling, `setEnabled(false)` makes the value nil and `isEnabled == false`.
  - `disableLeavesOtherViewer`: with the store preset to `"com.cocoatech.PathFinder"`, `isEnabled == false`, and after `setEnabled(false)` the value is still `"com.cocoatech.PathFinder"`.
  - `comparisonIgnoresCase`: with the store preset to `"DEV.NOIX.MacCommander"`, `isEnabled == true`.
- [ ] **Step 2:** Run `scripts/test.sh --filter FileViewerSettingTests`. Expected: the build fails because `FileViewerSetting` isn't defined.
- [ ] **Step 3:** Implement as in Interfaces.
- [ ] **Step 4:** Run `scripts/test.sh --filter FileViewerSettingTests`. Expected: 4 tests pass.
- [ ] **Step 5:** Commit: `feat: FileViewerSetting for the global NSFileViewer default`.

### Task 2: `OpenRequest` grouping and `BrowserModel.select` (Core)

**Files:**
- Create: `Sources/MacCommanderCore/Browser/OpenRequest.swift`
- Modify: `Sources/MacCommanderCore/Browser/BrowserModel.swift` (add `select`)
- Test: `Tests/MacCommanderCoreTests/OpenRequestTests.swift`, `Tests/MacCommanderCoreTests/BrowserModelTests.swift`

**Interfaces:**
- Produces:
  - `public struct OpenRequest: Equatable, Sendable { public let folder: URL; public let selection: [URL] }`
  - `public static func requests(for urls: [URL], isFolder: (URL) -> Bool) -> [OpenRequest]`. `isFolder` is true only for a real directory that isn't a package.
    - Non-file URLs are dropped. URLs are standardized.
    - Exactly one URL that `isFolder` → `[OpenRequest(folder: url, selection: [])]`.
    - Otherwise group by parent folder, in the order each parent first appears. Each item is listed once per group, in input order.
  - `public static func folderCheck(_ url: URL) -> Bool`: the real `isFolder`, a directory that is not a package (`URLResourceValues` `isDirectory` and `isPackage`). It may block, so callers run it via `PathQueries.run`.
  - `BrowserModel.select(_ urls: [URL]) async`: waits until the current folder's listing is loaded (it may still be running, since the model was just created), then sets `selection` to the items of `urls` whose parent is the current folder, spelled as in `items`. URLs from other folders are ignored.

- [ ] **Step 1: Write the failing tests** in `OpenRequestTests` (pure, with a closure `isFolder`):
  - `singleFolderOpensItself`: `["/a/Projects"]` with `isFolder` true → `[OpenRequest(folder: /a/Projects, selection: [])]`.
  - `filesGroupByParentInOrder`: `["/a/x.txt", "/b/y.txt", "/a/z.txt"]` → `[(/a, [/a/x.txt, /a/z.txt]), (/b, [/b/y.txt])]`.
  - `folderAmongOthersIsSelected`: `["/a/Projects" (folder), "/a/x.txt"]` → `[(/a, [/a/Projects, /a/x.txt])]`.
  - `packageIsSelectedInParent`: `["/Applications/Safari.app"]` with `isFolder` false → `[(/Applications, [/Applications/Safari.app])]`.
  - `missingPathIsTreatedAsFile`: `["/nope/gone.txt"]` with `isFolder` false → `[(/nope, [/nope/gone.txt])]`.
  - `nonFileURLsDropped`: `[https://example.com]` → `[]`.
  - `folderCheckRealDisk`: with a `TemporaryDirectory`, `folderCheck(dir.folder("f")) == true`, `folderCheck(dir.file("a.txt")) == false`, and `folderCheck(dir.folder("X.app")) == false` (a `.app` directory is a package).
- [ ] **Step 2: Add `selectRightAfterCreation`** to `BrowserModelTests`. Create a folder with `a.txt` and `b.txt`. Create `BrowserModel(start: folder, settings: makeStore())` **without** awaiting `reload()`. Then `await model.select([a, other folder's file])` makes `model.selection == [the item URL of a.txt]`.
- [ ] **Step 3:** Run `scripts/test.sh --filter "OpenRequestTests|BrowserModelTests/selectRightAfterCreation"`. Expected: the build fails.
- [ ] **Step 4:** Implement as in Interfaces. For `select`, reuse the model's existing reload and selection helpers (`reloadIfStillShowing`, `itemURL(matching:)`, as in `selectAfterOperation`).
- [ ] **Step 5:** Run the same filter. Expected: all pass.
- [ ] **Step 6:** Commit: `feat: OpenRequest grouping and BrowserModel.select`.

### Task 3: `GlobalShortcut` and `Preferences.globalShortcut` (Core)

**Files:**
- Create: `Sources/MacCommanderCore/Settings/GlobalShortcut.swift`
- Modify: `Sources/MacCommanderCore/Settings/Preferences.swift`
- Test: `Tests/MacCommanderCoreTests/GlobalShortcutTests.swift`, `Tests/MacCommanderCoreTests/PreferencesTests.swift`

**Interfaces:**
- Produces:
  - `public struct GlobalShortcut: Codable, Equatable, Sendable`
    - Stored properties: `keyCode: UInt16` (virtual key code), `modifiers: Modifiers`, and `key: String` (the key's label captured when recording, e.g. "M", "F5", "Space").
    - `public struct Modifiers: OptionSet, Codable, Sendable`: `command = 1`, `option = 2`, `control = 4`, `shift = 8`.
    - `public var isValid: Bool`: contains at least one of command, option or control.
    - `public var displayString: String`: the symbols in the order ⌃⌥⇧⌘, followed by `key`, e.g. "⌃⌥⌘M".
    - `public var carbonModifiers: UInt32`: `cmdKey` = 256, `shiftKey` = 512, `optionKey` = 2048, `controlKey` = 4096. Write the literal values; Core doesn't import Carbon.
  - `Preferences.globalShortcut: GlobalShortcut?`, default nil. Add it to `CodingKeys` and decode it leniently (unreadable means nil).

- [ ] **Step 1: Write the failing tests:**
  - `validityNeedsCommandOptionOrControl`: `[.shift]` is invalid, `[]` is invalid, `[.option]` is valid, `[.control, .shift]` is valid.
  - `displayOrder`: modifiers `[.command, .shift, .option, .control]` with key "M" → `"⌃⌥⇧⌘M"`.
  - `carbonMask`: `[.command, .option]` → `2304`. `[.control, .shift]` → `4608`.
  - `codableRoundTrip`: encoding and then decoding gives an equal value.
- [ ] **Step 2: Add to `PreferencesTests`:**
  - `globalShortcutDefaultsToNil`.
  - `globalShortcutRoundTrips`.
  - `unreadableGlobalShortcutIsNil`: JSON `{"globalShortcut": "garbage", "newFileName": "x.txt"}` decodes with `globalShortcut == nil` and `newFileName == "x.txt"`.
- [ ] **Step 3:** Run `scripts/test.sh --filter "GlobalShortcutTests|PreferencesTests"`. Expected: the build fails.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Run the same filter. Expected: all pass.
- [ ] **Step 6:** Commit: `feat: GlobalShortcut and Preferences.globalShortcut`.

### Task 4: Incoming opens, "Show in Finder" toggle, Reveal in Finder stays Finder (app)

**Files:**
- Modify: `Resources/Info.plist`: add `CFBundleDocumentTypes` with one entry: `CFBundleTypeName` "Folder", `CFBundleTypeRole` "Viewer", `LSHandlerRank` "Alternate", `LSItemContentTypes` `["public.folder"]`.
- Create: `Sources/MacCommander/App/OpenRequestRouter.swift`
- Modify: `Sources/MacCommander/App/MacCommanderApp.swift` (AppDelegate)
- Modify: `Sources/MacCommander/Browser/BrowserWindow.swift`
- Modify: `Sources/MacCommander/Settings/GeneralSettings.swift`

**Interfaces:**
- Consumes: `OpenRequest.requests(for:isFolder:)`, `OpenRequest.folderCheck`, `BrowserModel.select`, `FileViewerSetting`, `CFGlobalDefaultsStore`, `PathQueries.run`.
- Produces: `@MainActor final class OpenRequestRouter` (one per app, owned by `AppDelegate`, put in the environment). It has:
  - `func receive(_ urls: [URL])`: groups the URLs off the main actor, then calls `enqueue`.
  - `func enqueue(_ requests: [OpenRequest])`: appends to `pending`, and calls `openWindow` once per request when it is set.
  - `var openWindow: (() -> Void)?`: set from the first `BrowserWindow`'s `@Environment(\.openWindow)`, opening the main `WindowGroup`.
  - `func takePending() -> OpenRequest?`
  - `private(set) var browserWindowCount: Int`, maintained by `windowAppeared()` and `windowDisappeared()`.
  - `func openNewWindow()`: used by Task 5's hotkey.

**Router rules** (they decide Review Focus 1):
- **Who consumes a request:** a `BrowserWindow` whose scene storage is empty (a fresh window) takes one pending request in `onAppear`, if any. It starts its first pane at `request.folder`, skips the preferred-folder replacement, and then calls `model.select(request.selection)` when the selection isn't empty.
- **Restored windows** never consume a request.
- **Cold launch:** requests that arrive before any window has registered `openWindow` are only queued. When the first window registers `openWindow`, it first consumes one request if it is fresh, and then calls `openWindow` once for each request still pending.

**Other changes:**
- **`AppDelegate.application(_:open:)`** passes the file URLs to `router.receive`.
- **Our own "Reveal in Finder":** in `applicationWillFinishLaunching`, write `UserDefaults.standard.set("com.apple.finder", forKey: "NSFileViewer")`. That puts the value in the app's own domain, which overrides the global one for this process only (verified in the spike). `FileActions.revealInFinder` stays unchanged.
- **Settings ▸ General** gets a new Section with the toggle "Use MacCommander for “Show in Finder”".
  - It is bound to `FileViewerSetting(bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.noix.MacCommander", store: CFGlobalDefaultsStore())`.
  - It re-reads the value in `onAppear`.
  - Below it, a caption: "Other apps’ “Show in Finder” opens a MacCommander window. Folders opened from Spotlight or the Dock still open in the Finder."

- [ ] **Step 1:** Implement as above. The app target has no unit tests; the Core pieces are covered by Tasks 1–2.
- [ ] **Step 2:** `swift build` → "Build complete!". `scripts/test.sh` → all tests pass.
- [ ] **Step 3:** Commit: `feat: open folders and reveals in new windows; Show in Finder toggle`.
- [ ] **Manual checks** (for the user; don't launch the app yourself while theirs runs):
  - **M1:** toggle on, then Safari ▸ Downloads ▸ "Show in Finder" opens a new MacCommander window with the file selected.
  - **M2:** same as M1 with MacCommander quit first: exactly one window, at the target.
  - **M3:** MacCommander's own Reveal in Finder still opens the Finder.
  - **M4:** dropping a folder on the Dock icon opens that folder. `open -a MacCommander ~/Downloads ~/Desktop/x.txt` opens two windows.
  - **M5:** toggle off → `defaults read -g NSFileViewer` reports the key missing. With Path Finder's id set by hand, the toggle shows off and turning it off leaves the value.

### Task 5: Global hotkey (app)

**Files:**
- Create: `Sources/MacCommander/App/HotKeyCenter.swift`
- Create: `Sources/MacCommander/Settings/ShortcutRecorder.swift`
- Modify: `Sources/MacCommander/App/MacCommanderApp.swift`
- Modify: `Sources/MacCommander/Settings/GeneralSettings.swift`

**Interfaces:**
- Consumes: `GlobalShortcut`, `Preferences.globalShortcut`, and `OpenRequestRouter.openNewWindow()` / `browserWindowCount`.
- Produces: `@MainActor final class HotKeyCenter`, owned by `AppDelegate`.
  - `func register(_ shortcut: GlobalShortcut?, action: @escaping @MainActor () -> Void) -> Bool`
    - Unregisters the previous hotkey first.
    - nil means off and returns true.
    - Returns false when `RegisterEventHotKey` fails (OSStatus != noErr). The previous registration is then restored.
    - Uses `InstallEventHandler` on the application event target for `kEventClassKeyboard`/`kEventHotKeyPressed`, installed once.

**Behavior:**
- **The hotkey's action:** `NSApp.activate()`. If `router.browserWindowCount == 0`, it calls `router.openNewWindow()`. Otherwise it brings the browser windows to the front (activating is enough).
- **At launch,** `AppDelegate` registers `preferences.preferences.globalShortcut`. If that fails, the shortcut stays stored but inactive; there is no alert at launch.
- **Recording a shortcut:** `ShortcutRecorder` is a SwiftUI view wrapping a small `NSView` that becomes first responder on click and captures the next `keyDown` through `NSEvent` (keyCode, the modifier flags mapped to `GlobalShortcut.Modifiers`, and `charactersIgnoringModifiers?.uppercased()`, with names for special keys: "Space", "Return", "Tab", "Delete", "Esc", "F1"–"F20", "←→↑↓").
  - Esc without modifiers cancels the recording.
  - A shortcut that isn't `isValid` is ignored, and the recorder keeps waiting.
- **Settings ▸ General row:** `LabeledContent("Global hotkey")` with the recorder (showing `displayString`, or "Click to record") and a Clear button.
  - A recorded shortcut is first passed to `HotKeyCenter.register`.
  - On success, it is stored in `preferences.preferences.globalShortcut`.
  - On failure, the row shows "This shortcut is already in use" in red, and the stored value is left unchanged.
  - Clear stores nil and unregisters.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `swift build` → "Build complete!". `scripts/test.sh` → all tests pass.
- [ ] **Step 3:** Commit: `feat: global hotkey to bring MacCommander to the front`.
- [ ] **Manual checks:**
  - **M6:** record ⌃⌥⌘M, switch to another app, press it → MacCommander comes to the front.
  - **M7:** close all windows, press it → a new window opens at the "New windows open" folder.
  - **M8:** recording ⌘Space (Spotlight) shows "This shortcut is already in use". If macOS lets it register anyway, note that for the user.
  - **M9:** quit and relaunch → the hotkey still works. Clear → it no longer reacts.
