# MacCommander Plan 7: Dual-Pane Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in Total Commander-style mode: two independent folder panes in one window, with F5/F6 (⌘5/⌘6), drag and drop and context-menu copy/move between them.

**Architecture:**
- **Core** gets `PaneLayout` (one or two `BrowserModel`s per window, the active pane, mode switching, swap / same folder, per-pane search text, the pending transfer) and `PaneTransfer` (pure helpers: top-level selection, destination parsing, request building). `Preferences` gets `dualPaneEnabled`; `ViewSettings` gets a separate preview flag for dual-pane windows.
- **UI**: today's per-folder parts of `BrowserWindow` (file list, truncation notice, path bar, per-model tasks) move into a `PaneView`. `BrowserWindow` owns a `PaneLayout` and shows its panes in the existing `HSplitView`. Every window-level consumer (sidebar, toolbar, search field, preview, sheets, focused values for the menus) reads `layout.active`. `FileListController` / `FileOutlineView` get small pane hooks (activation, Tab, F-keys, context-menu items).
- Neither `BrowserModel` nor the file-list internals learn about dual-pane beyond those hooks.

**Tech Stack:** Swift 6, SwiftPM (Command Line Tools only), SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-19-dual-pane-design.md` (builds on `docs/superpowers/specs/2026-11-17-maccommander-design.md`).

## Global Constraints

- Swift 6, macOS 15 minimum. Command Line Tools only: run tests with `scripts/test.sh`, build the app with `scripts/build-app.sh`. The `@State` and `@Entry` macros are unavailable in views: use `State<T>` properties and hand-written `FocusedValueKey`s, as in `BrowserWindow.swift`. `@Observable` on classes works.
- Core logic lives in `MacCommanderCore` with Swift Testing unit tests; the UI in `MacCommander` is verified by building and by the manual checks at the end.
- **Never block the main thread on file-system calls**: blocking checks go through `PathQueries.run`. A slow or dead NAS in one pane must never freeze the other pane or the F5 sheet (spec §1).
- **Opt-in**: `Preferences.dualPaneEnabled`, default **false**. While false the app looks and behaves exactly like v1: no ⌘2 / Dual Pane item, no toolbar button, no Swap Panes / Same Folder in Other Pane / Copy to Other Pane / Move to Other Pane, and F5/F6/⌘5/⌘6 do nothing (spec §2.1).
- Turning the setting off switches every open dual-pane window to single-pane, keeping its active pane. Turning it on switches no window by itself.
- Copy/move/extract between panes go only through the existing `FileActions.transfer` / `FileActions.extract` paths (progress strip, Cancel, conflict dialog, Undo).
- Keys: **⌘1** Single Pane, **⌘2** Dual Pane; **F5 / ⌘5** copy, **F6 / ⌘6** move to the other pane; **F7** New Folder; **F8** Move to Trash; **Tab / ⇧Tab** switch panes (dual only). ⌘F5 is never bound (macOS VoiceOver).
- Copy (verbatim): sheet title "Copy “<name>” to:" / "Copy <n> items to:" / "Move “<name>” to:" / "Move <n> items to:" / "Extract “<name>” to:" / "Extract <n> items to:"; menu items "Single Pane", "Dual Pane", "Swap Panes", "Same Folder in Other Pane", "Copy to Other Pane", "Move to Other Pane"; settings checkbox "Enable dual-pane mode". All strings `String(localized:)`.
- Tests must never touch the real Trash, the real Keychain or `UserDefaults.standard` (use `TemporaryDefaults`).
- Git: work on `main`, no worktrees, commit per task, commit messages end with the `Co-Authored-By` trailer.

## Rulings made while planning (what — why — cost if wrong)

- **P7-1** With nothing selected, F5/F6 beep instead of using "the focused row" (spec §2.5). — `NSOutlineView` has no focused-but-unselected row; selection is the only cursor. — Cost: none visible; the spec's case cannot occur.
- **P7-2** In single-pane mode the kept pane is always `panes[0]`; turning dual-pane on again appends the new pane on the right. — One slot order to persist. — Cost: if the right pane was the one kept, the remembered folder reappears on the right instead of the left.
- **P7-3** New windows (⌘N) always start single-pane. — The spec makes the mode per window and only restores it. — Cost: a dual-pane user presses ⌘2 per new window.
- **P7-4** One `PreviewController` per pane; the inactive pane's controller is stopped. — `PreviewController` is bound to one model. — Cost: switching panes re-renders the preview.
- **P7-5** F5–F8 and Tab are handled in `FileOutlineView.keyDown` (list focused); ⌘1/⌘2/⌘5/⌘6 are SwiftUI menu shortcuts. — Function keys as SwiftUI `KeyEquivalent` are unreliable; menus can't show F-key equivalents anyway. — Cost: F5 does nothing while the search field has focus (⌘5 still works).
- **P7-6** Divider position is not persisted (spec §7 lists it as nice to have).

## Review Focus

1. A menu command or sidebar click while the right pane is active must act on the right pane, never on the left (the wrong-direction copy). Pinned by `PaneLayoutTests.activeFollowsActivation` and manual check M3.
2. The other pane shows a search, tag view, archive or Disconnected placeholder → F5/F6 are refused (no sheet). Pinned by `PaneTransferTests.noTargetWhenOtherPaneIsNotARealFolder`.
3. A selection containing a folder and rows of its expanded children copies only the folder. Pinned by `PaneTransferTests.topLevelDropsDescendants`.
4. Turning dual-pane off while the right pane is active keeps the right pane's model (history, search) as the only pane. Pinned by `PaneLayoutTests.showSingleKeepsActivePane`.
5. The sheet's destination check against a dead NAS must not block the UI and must not hang forever on confirm. Pinned by `PaneTransferTests.parseDestination*` (pure) and manual check M6.

---

### Task 1: Preferences and preview settings

**Files:**
- Modify: `Sources/MacCommanderCore/Settings/Preferences.swift`
- Modify: `Sources/MacCommanderCore/Settings/ViewSettings.swift`
- Modify: `Sources/MacCommander/Settings/GeneralSettings.swift`
- Test: `Tests/MacCommanderCoreTests/PreferencesTests.swift`, `Tests/MacCommanderCoreTests/ViewSettingsStoreTests.swift`

**Interfaces:**
- Produces: `Preferences.dualPaneEnabled: Bool` (default `false`, lenient decoding, new `CodingKeys` case, `init` parameter with default). `ViewSettings.showPreviewInDualPane: Bool` (default `false`, lenient decoding); `ViewSettings.showsPreview(dualPane: Bool) -> Bool`; `mutating ViewSettings.togglePreview(dualPane: Bool)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func dualPaneDefaultsOffAndRoundTrips() {
    // fresh store → false; set true → new store on the same suite reads true
}
@Test func dualPaneDecodesLeniently() {
    // stored JSON without "dualPaneEnabled" → false, other fields kept;
    // {"dualPaneEnabled": "yes"} → false
}
@Test func previewIsSeparatePerMode() {
    var s = ViewSettings()
    #expect(s.showsPreview(dualPane: false) == false && s.showsPreview(dualPane: true) == false)
    s.togglePreview(dualPane: false)
    #expect(s.showPreview && !s.showPreviewInDualPane)
    s.togglePreview(dualPane: true)
    #expect(s.showsPreview(dualPane: true))
}
@Test func dualPreviewDecodesLeniently() { // missing key → false, persisted value round-trips through ViewSettingsStore
}
```

- [ ] **Step 2: Run** `scripts/test.sh --filter "PreferencesTests|ViewSettingsStoreTests"` — expect compile failure.
- [ ] **Step 3: Implement** the fields and helpers above. Add a `Toggle("Enable dual-pane mode", …)` to `GeneralSettings` bound to `preferences.preferences.dualPaneEnabled`, with the footnote text "Adds a second folder pane to windows (View ▸ Dual Pane, ⌘2)."
- [ ] **Step 4: Run** the same filter, then `scripts/test.sh` — all pass.
- [ ] **Step 5: Commit** `feat: dual-pane preference and per-mode preview setting`.

---

### Task 2: PaneLayout

**Files:**
- Create: `Sources/MacCommanderCore/Browser/PaneLayout.swift`
- Test: `Tests/MacCommanderCoreTests/PaneLayoutTests.swift`

**Interfaces:**
- Consumes: `BrowserModel` (`currentURL`, `navigate(to:)`, `isSearching`, `archiveLocation`, `loadError`, `disconnectedShare`, `search`).
- Produces:

```swift
@MainActor @Observable
public final class PaneLayout {
    public init(primary: BrowserModel, rememberedSecondFolder: URL? = nil,
                makePane: @escaping @MainActor (URL) -> BrowserModel)
    /// One or two panes; panes[0] is the left. In single-pane mode the only pane is panes[0].
    public private(set) var panes: [BrowserModel]
    public private(set) var activeIndex: Int
    public var isDual: Bool { get }
    public var active: BrowserModel { get }
    public var inactive: BrowserModel? { get }           // nil in single-pane mode
    public private(set) var rememberedSecondFolder: URL?
    /// Incremented whenever a pane should take keyboard focus; `focusTarget` is that pane.
    public private(set) var focusSerial: Int
    public private(set) var focusTarget: ObjectIdentifier?

    public func showDual()                 // no-op when dual
    public func showSingle()               // no-op when single
    public func activate(_ pane: BrowserModel)       // unknown pane: ignored
    public func switchActive()             // dual only; also requests focus for the new active pane
    public func requestFocus(_ pane: BrowserModel)

    public func searchText(for pane: BrowserModel) -> String
    public func setSearchText(_ text: String, for pane: BrowserModel)

    /// The inactive pane's folder when it shows a real folder (no search/tag view, not in an archive,
    /// no load error, not disconnected); else nil. Always nil in single-pane mode.
    public var transferTarget: URL? { get }
    public var canShowActiveFolderInOtherPane: Bool { get }   // dual, active shows a real folder (same rules)
    public func swapFolders() async        // dual only
    public func showActiveFolderInOtherPane() async
}
```

Behavior:
- `showDual()`: creates the second pane with `makePane(rememberedSecondFolder ?? active.currentURL)`, appends it at index 1, keeps `activeIndex`.
- `showSingle()`: sets `rememberedSecondFolder` to the inactive pane's `currentURL`, removes the inactive pane (and its search text), the kept pane becomes `panes[0]`, `activeIndex = 0` (Ruling P7-2).
- `swapFolders()`: captures both `currentURL`s first, then navigates each pane to the other's (two history entries; Back undoes per pane).
- `showActiveFolderInOtherPane()`: navigates the inactive pane to `active.currentURL`; no-op unless `canShowActiveFolderInOtherPane`.

- [ ] **Step 1: Write the failing tests** (`@MainActor`, real `BrowserModel`s on `TemporaryDirectory` folders and a `ViewSettingsStore` on `TemporaryDefaults`, as in `BrowserModelTests`):

```swift
@Test func startsSingleWithPrimaryActive()        // panes.count == 1, isDual false, active === primary, inactive nil, transferTarget nil
@Test func showDualOpensSameFolderFirstTime()     // second pane's currentURL == primary.currentURL, activeIndex 0
@Test func showDualReopensRememberedFolder()      // showDual, navigate panes[1] to B, showSingle, showDual → panes[1].currentURL == B
@Test func showSingleKeepsActivePane()            // dual, activate(panes[1]) → showSingle → panes == [formerRight], activeIndex 0, remembered == left's folder
@Test func activeFollowsActivation()              // activate(right) → active === right, inactive === left; activate(unknown model) → unchanged
@Test func switchActiveRequestsFocus()            // switchActive → activeIndex flips, focusSerial increments, focusTarget == ObjectIdentifier(new active)
@Test func searchTextIsPerPane()                  // set "a" for left, "b" for right → each reads its own; showSingle drops the removed pane's text
@Test func transferTargetIsOtherPaneFolder()      // dual, left active → transferTarget == right.currentURL
@Test func swapFoldersExchangesAndBackRestores()  // left A, right B → swap → left B, right A; left.goBack() → A
@Test func sameFolderInOtherPane()                // left A active, right B → showActiveFolderInOtherPane → right.currentURL == A
```

- [ ] **Step 2: Run** `scripts/test.sh --filter PaneLayoutTests` — compile failure.
- [ ] **Step 3: Implement** `PaneLayout` as specified. Search texts are a `[ObjectIdentifier: String]`.
- [ ] **Step 4: Run** the filter, then `scripts/test.sh` — all pass.
- [ ] **Step 5: Commit** `feat: PaneLayout for one or two panes per window`.

---

### Task 3: PaneTransfer

**Files:**
- Create: `Sources/MacCommanderCore/Browser/PaneTransfer.swift`
- Test: `Tests/MacCommanderCoreTests/PaneTransferTests.swift`

**Interfaces:**
- Consumes: `PaneLayout` (Task 2), `ArchivePath.inner(of:in:)`, `BrowserModel.selection`, `BrowserModel.archiveLocation`.
- Produces:

```swift
public enum PaneTransferKind: Equatable, Sendable { case copy, move, extract(archive: URL) }

public struct PaneTransferRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: PaneTransferKind
    public let sources: [URL]        // top-level selection, sorted by path
    public let entries: [String]     // inner paths for .extract, same order as sources; empty otherwise
    public let destination: URL      // proposed: the other pane's folder
    public var title: String { get } // the verbatim sheet titles from Global Constraints
}

public enum PaneTransfer {
    /// Drops every URL that has an ancestor in the set; sorted by standardized path.
    public static func topLevel(_ urls: Set<URL>) -> [URL]
    /// Trims whitespace; "~" and "~/…" expand against `home`; must then start with "/"; returns the
    /// standardized directory URL, or nil (empty, relative, "~user").
    public static func parseDestination(_ text: String, home: URL) -> URL?
}

extension PaneLayout {
    /// nil (caller beeps) when: not dual, no `transferTarget`, empty selection, or move from an archive.
    /// Copy from an archive becomes `.extract(archive:)`.
    public func transferRequest(move: Bool) -> PaneTransferRequest?
    /// The request the window's sheet shows; set by `requestTransfer`, cleared by the sheet.
    public var pendingTransfer: PaneTransferRequest? { get set }
    /// Sets `pendingTransfer` from `transferRequest(move:)`; false when there is none.
    @discardableResult public func requestTransfer(move: Bool) -> Bool
}
```

(`pendingTransfer` is a stored property of `PaneLayout`; add it there.)

- [ ] **Step 1: Write the failing tests**

```swift
@Test func topLevelDropsDescendants()   // {/a, /a/b, /a/b/c, /d} → [/a, /d]; "/ab" is not under "/a"
@Test func parseDestinationExpandsHome() // "~" → home; " ~/x/ " → home/x; "/tmp/../tmp" → /tmp
@Test func parseDestinationRejectsRelative() // "", "x/y", "~bob/x" → nil
@Test func copyRequestUsesOtherPaneFolder() // dual, left selection {f1, f2} → .copy, sources sorted, destination == right.currentURL, title "Copy 2 items to:"
@Test func singleItemTitleNamesIt()         // one file "report.pdf", move → "Move “report.pdf” to:"
@Test func noRequestWhenSingleOrEmpty()     // single-pane → nil; dual with empty selection → nil
@Test func noTargetWhenOtherPaneIsNotARealFolder() // right pane searching (startSearch on a temp folder) → nil; right pane in an archive (fixture zip via ArchiveFixtures) → nil
@Test func archiveSourceExtractsAndRefusesMove()   // left browsing a fixture zip, selection of two entries → copy gives .extract(archive:) with inner paths, title "Extract 2 items to:"; move → nil
@Test func requestTransferSetsPending()            // requestTransfer(move: false) == true, pendingTransfer != nil; when impossible → false, pending stays nil
```

- [ ] **Step 2: Run** `scripts/test.sh --filter PaneTransferTests` — compile failure.
- [ ] **Step 3: Implement.** Titles use the source's `lastPathComponent` for one item.
- [ ] **Step 4: Run** the filter, then `scripts/test.sh` — all pass.
- [ ] **Step 5: Commit** `feat: PaneTransfer requests between panes`.

---

### Task 4: Extract PaneView (single pane, no visible change)

A refactor only: after this task the app looks and behaves exactly as before, but `BrowserWindow` holds a `PaneLayout` (always single) and renders its pane through `PaneView`.

**Files:**
- Create: `Sources/MacCommander/Browser/PaneView.swift`
- Modify: `Sources/MacCommander/Browser/BrowserWindow.swift`

**Interfaces:**
- Consumes: `PaneLayout` (Task 2).
- Produces:
  - `struct PaneView: View` with `init(model: BrowserModel, layout: PaneLayout, isActive: Bool, showsActiveMarker: Bool, onFolderChange: @escaping (URL) -> Void)`. It contains, top to bottom: `FileListView` (with today's `reconnect`/`signIn` closures, moved here), the search-truncation notice, `Divider`, `PathBar`. It owns the per-model work that today sits on the window: `.task { await model.reload() }`, `.onChange(of: model.currentURL, initial: true)` → `onFolderChange`, the refresh-on-focus `.onChange(of: appearsActive)`, and clearing its own search text in the layout when its `model.search` ends or leaves the folder (today's `.onChange(of: model.search)`).
  - `BrowserWindow.makeModel(start: URL) -> BrowserModel`: today's `onAppear` model setup (`newFileName`, `shareResolver`, `shareDropped`), reused for every pane.
- The window keeps: sidebar, toolbar, `.searchable` (bound to `layout.searchText(for: layout.active)` / `setSearchText`), the debounced search `.task` (its id must include the active pane's `ObjectIdentifier` and the text; when the pane changes and that pane's `model.search?.text` already equals the text, do not restart), title, focused values, sheets, `OperationsStrip`, the preview and the new-window start (`replaceStart`).
- Panes are rendered with `ForEach(layout.panes, id: \.paneID)` (add `extension BrowserModel { var paneID: ObjectIdentifier { ObjectIdentifier(self) } }` in `PaneView.swift`), inside the existing `HSplitView`, so a pane keeps its list controller when another pane is added or removed.
- Preview: a `[ObjectIdentifier: PreviewController]` in window state, created lazily per pane; the active pane's controller is shown and `resume()`d, every other one `stop()`ped (Ruling P7-4). `onDisappear` stops all.

- [ ] **Step 1: Implement** the refactor. `currentFolderPath` scene storage is written from `panes[0]`'s `onFolderChange`.
- [ ] **Step 2: Build** `scripts/build-app.sh` — BUILD OK. Run `scripts/test.sh` — all pass.
- [ ] **Step 3: Smoke-check by launching** `scripts/build-app.sh --open`: navigate, search, clear search, Back closes search, preview toggles, relaunch restores the folder. Record the result in the report.
- [ ] **Step 4: Commit** `refactor: move per-folder window parts into PaneView`.

---

### Task 5: Dual-pane window

**Files:**
- Modify: `Sources/MacCommander/Browser/BrowserWindow.swift`, `Sources/MacCommander/Browser/PaneView.swift`, `Sources/MacCommander/Browser/PathBar.swift`
- Modify: `Sources/MacCommander/FileList/FileOutlineView.swift`, `FileListController.swift`, `FileListView.swift`
- Modify: `Sources/MacCommander/App/BrowserCommands.swift`, `Sources/MacCommander/App/MacCommanderApp.swift` (pass `PreferencesStore` to `BrowserCommands`)

**Interfaces:**
- Consumes: Tasks 1, 2, 4.
- Produces:
  - Focused value `\.paneLayout: PaneLayout?` (hand-written key), published by the window; `\.browserModel` now publishes `layout.active`.
  - `FileListView` gains `onActivate: (() -> Void)?`, `onSwitchPane: (() -> Void)?` (nil in single-pane mode), `focusSerial: Int` + `isFocusTarget: Bool` (the controller makes its outline first responder when `focusSerial` changed since it last applied one and it is the target).
  - `FileOutlineView`: `onBecomeFirstResponder` (called from `becomeFirstResponder()` when it returns true) → `onActivate`; Tab (keyCode 48) and ⇧Tab without other modifiers → `onSwitchPane` when set, else `super`.
  - `PathBar(model:isActive:)`: active → path text in `.primary` and semibold; inactive → `.secondary`. In single-pane mode always active styling.

Steps:
- [ ] **Step 1: Mode switching.** View menu (after the Show Hidden/Checkbox items, separated): "Single Pane" ⌘1 and "Dual Pane" ⌘2, as a checkmarked pair; only present when `preferences.dualPaneEnabled`. Toolbar button (system image `rectangle.split.2x1`, label "Dual Pane") toggling the mode, only present when enabled. `.onChange(of: preferences.preferences.dualPaneEnabled)`: false → `layout.showSingle()`.
- [ ] **Step 2: Persistence.** Scene storage keys: `currentFolderPath` (panes[0], unchanged key), `secondFolderPath` (panes[1], or `rememberedSecondFolder` in single mode), `isDualPane` (Bool), `activePane` (Int). Restore on appear: build `PaneLayout(primary:rememberedSecondFolder:makePane:)`; when `isDualPane` and the preference is on, `showDual()` and `activate(panes[activePane])`. A gone folder uses the model's existing nearest-ancestor fallback. New windows start single (Ruling P7-3).
- [ ] **Step 3: Active pane.** `PaneView` draws a 2 pt accent-colored leading edge when `showsActiveMarker && isActive` (only in dual-pane mode); clicking the path bar or the load-error / Disconnected placeholder activates the pane (`simultaneousGesture(TapGesture())`); the list activates through `onActivate`. Tab / ⇧Tab call `layout.switchActive()`. The sidebar, toolbar Back/Forward/New Folder, search field, title, `GoToFolderSheet`, `ConnectToServerSheet`, `SignInSheet` and all focused values use `layout.active`.
- [ ] **Step 4: Preview per mode.** The toolbar Preview button and View ▸ Show/Hide Preview (⇧⌘P) read and toggle `settings.showsPreview(dualPane:)` / `togglePreview(dualPane:)` for the focused window's mode (via `\.paneLayout`). Panes `minWidth: 200`, preview `minWidth: 240`.
- [ ] **Step 5: Build and test** — `scripts/build-app.sh` BUILD OK, `scripts/test.sh` all pass.
- [ ] **Step 6: Smoke-check** with the setting on: ⌘2 shows two panes on the same folder; clicking / Tab moves the marker; ⌘[ and a sidebar click act on the marked pane; search text is per pane; ⌘1 keeps the marked pane; relaunch restores both folders and the mode; setting off collapses the window. Record in the report.
- [ ] **Step 7: Commit** `feat: dual-pane windows with an active pane`.

---

### Task 6: Copy, move and Total Commander commands

**Files:**
- Create: `Sources/MacCommander/Browser/PaneTransferSheet.swift`
- Modify: `Sources/MacCommander/Browser/BrowserWindow.swift`, `Sources/MacCommander/App/BrowserCommands.swift`
- Modify: `Sources/MacCommander/FileList/FileOutlineView.swift`, `FileListController.swift`, `FileListView.swift`, `FileContextMenu.swift`

**Interfaces:**
- Consumes: Tasks 2, 3, 5; `FileActions.transfer(_:into:mode:model:window:)`, `FileActions.extract(_:from:into:model:window:)`, `BrowserActions.newFolder(_:)`, `FileCommand.moveToTrash`.
- Produces:
  - `PaneTransferSheet(request: PaneTransferRequest, onConfirm: (URL) -> Void, onCancel: () -> Void)`: the request's `title`, a text field preloaded with `request.destination.path` (text selected), Cancel (`.cancelAction`) and OK (`.defaultAction`). On OK: `PaneTransfer.parseDestination`; nil → inline error "Enter a full folder path, starting with / or ~." Otherwise check "exists and is a directory" through `PathQueries.run` while a small progress indicator shows and OK is disabled (Cancel stays enabled and abandons the check); not a folder → inline error "There’s no folder at this path."; else `onConfirm(url)`.
  - `FileListView` / `FileListController` gain `paneCommands: PaneCommands?`:
    ```swift
    struct PaneCommands {
        let canTransfer: () -> Bool          // layout.transferRequest(move: false) != nil
        let requestTransfer: (_ move: Bool) -> Bool
    }
    ```
    nil while dual-pane is not enabled or the window is single-pane.

Steps:
- [ ] **Step 1: Sheet and window wiring.** The window presents `.sheet(item: $layout.pendingTransfer)`. Confirm: `.copy`/`.move` → `FileActions.transfer(sources, into: url, mode:, model: layout.inactive ?? layout.active, window:)` (results get selected in the target pane when it shows that folder); `.extract(archive)` → `FileActions.extract(entries, from: archive, into: url, model: layout.inactive ?? layout.active, window:)`. The pane's own folder never changes because of an edited path.
- [ ] **Step 2: Keys.** In `FileOutlineView.keyDown`, with no modifiers: F5 (`.f5`) → `requestTransfer(false)`, F6 → `requestTransfer(true)` (beep when it returns false or `paneCommands` is nil); F7 → New Folder in this list's model (`BrowserActions.newFolder`, beeps in archive/search as today); F8 → `commandHandler?.perform(.moveToTrash)`. F7/F8 work in single-pane mode and with the setting off.
- [ ] **Step 3: Menus.** File menu after Duplicate: "Copy to Other Pane" ⌘5, "Move to Other Pane" ⌘6, disabled unless `layout.transferRequest(move:) != nil`; View menu (with the pane items): "Swap Panes" and "Same Folder in Other Pane" (disabled unless dual / `canShowActiveFolderInOtherPane`). All four absent when the preference is off.
- [ ] **Step 4: Context menu.** `FileContextMenu.forItems` gets "Copy to Other Pane" / "Move to Other Pane" after Copy/Cut when `paneCommands` is non-nil; disabled when no request is possible (Move also disabled inside an archive). They call `requestTransfer`.
- [ ] **Step 5: Drag and drop.** No code expected: dropping on the other pane's list already uses `acceptDrop`. Verify it in the smoke check; if a drop onto the inactive pane is refused or lands in the wrong folder, fix it in `FileListController+Outline.swift`.
- [ ] **Step 6: Build and test** — BUILD OK, all tests pass.
- [ ] **Step 7: Smoke-check**: F5 / ⌘5 sheet → Enter copies into the right pane with progress; edited path copies there and the pane stays; bogus path shows the error; F6 moves and ⌘Z undoes; F5 on archive entries says "Extract …" and extracts; right pane searching → F5 beeps; F7/F8 work in single-pane mode; drag left→right copies across volumes / moves on the same volume. Record in the report.
- [ ] **Step 8: Commit** `feat: copy and move between panes (F5/F6, menus, sheet)`.

---

## Manual checks for the user (after all tasks)

- **M1** Setting off (default): the app looks exactly like before — no ⌘1/⌘2, no toolbar button, F5/⌘5 do nothing.
- **M2** Setting on, ⌘2: two panes on the same folder; ⌘1 / setting off collapse to the marked pane; relaunch restores mode and both folders.
- **M3** Active pane: click and Tab move the marker; sidebar, Back, ⇧⌘G, ⌘F search, ⌘I, Space, preview all act on the marked pane.
- **M4** F5 NAS → local and local → local: sheet, Enter, progress, conflict dialog on a duplicate, ⌘Z.
- **M5** F6 move; drag between panes (same volume moves, NAS ↔ local copies, ⌥ forces copy); context-menu Copy/Move to Other Pane.
- **M6** NAS switched off: the NAS pane shows Disconnected; the local pane stays usable; F5 toward the dead pane is refused; an edited path onto the dead share doesn't freeze the sheet (Cancel works).
- **M7** Archives: F5 on entries extracts into the other pane (password prompt for an encrypted one); F6 refused.
- **M8** Swap Panes, Same Folder in Other Pane, F7, F8.
