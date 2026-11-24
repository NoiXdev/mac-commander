# Settings with a sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tabbed Settings window with a macSCP-style sidebar layout in a freely resizable window that remembers its size.

**Architecture:** A `SettingsSection` enum in Core holds the order, titles and symbols of the seven sections. `SettingsView` becomes a `NavigationSplitView` over that enum. Today's `GeneralSettings` is split into four panes (General, View, Terminal, Shortcuts). A window accessor makes the Settings window resizable and sets its frame autosave name.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Swift Testing (`scripts/test.sh`), app bundle via `scripts/build-app.sh`.

**Spec:** `docs/superpowers/specs/2026-11-24-settings-sidebar-design.md`

## Global Constraints

- Branch: `improvements`. Conventional Commits. Commit only when the user asks: the commit steps below are run once the user has approved committing on this branch.
- macOS 15+, no new package dependencies.
- No control changes its store, wording or behavior. Only the pane it sits in changes.
- Sidebar column fixed at **180 pt**. Detail column `min: 460`. One constant for the window minimum, used for both the SwiftUI frame and `contentMinSize`.
- Frame autosave name: **`MacCommander.settings`**.
- User-visible strings stay `String(localized:)` in English. Translation is a separate plan that follows this one.
- User docs (noix-docs `maccommander/`) are updated once, at the end of the `improvements` branch, not in this plan.

## Review Focus

- **Opening Settings a second time** (close and ⌘, again): the window must come back at the remembered size, not at the minimum, and still be resizable.
- **Shrinking the window to its minimum** on the tallest section: nothing is clipped; the form scrolls if it must.
- **General ▸ "Choose…"** for the new-window folder: the open panel must still appear as a sheet on the Settings window. `WindowReader` now sits in the General pane, which is only in the hierarchy while General is selected.
- **Hotkey recorder in Shortcuts:** recording a taken shortcut still shows "This shortcut is already in use"; switching sections and back clears nothing that was saved.
- **Network sheets and alerts** (Connect to Server…, Edit…, Remove…) still attach to the Settings window from the detail column.

---

### Task 1: `SettingsSection` in Core

**Files:**
- Create: `Sources/MacCommanderCore/Settings/SettingsSection.swift`
- Test: `Tests/MacCommanderCoreTests/SettingsSectionTests.swift`

**Interfaces:**
- Produces: `public enum SettingsSection: String, CaseIterable, Hashable, Sendable { case general, view, terminal, shortcuts, sidebar, tags, network }` with `public var title: String` (`String(localized:)`: "General", "View", "Terminal", "Shortcuts", "Sidebar", "Tags", "Network") and `public var systemImage: String` (`gearshape`, `eye`, `terminal`, `keyboard`, `sidebar.left`, `tag`, `network`). `allCases` order is the sidebar order.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func sidebarOrderMatchesTheSpec() {
    #expect(SettingsSection.allCases == [.general, .view, .terminal, .shortcuts, .sidebar, .tags, .network])
}
@Test func everySectionHasItsOwnSymbolAndTitle() {
    let all = SettingsSection.allCases
    #expect(Set(all.map(\.systemImage)).count == all.count)
    #expect(Set(all.map(\.title)).count == all.count)
    #expect(SettingsSection.view.title == "View")
    #expect(SettingsSection.shortcuts.systemImage == "keyboard")
}
```

- [ ] **Step 2: Run `scripts/test.sh` and see both fail** (`SettingsSection` not defined).
- [ ] **Step 3: Implement the enum** as in the Interfaces block, with a doc comment naming it as the Settings sidebar's source of truth.
- [ ] **Step 4: Run `scripts/test.sh`.** Expected: all tests pass (604 + 2).
- [ ] **Step 5: Commit** `feat(settings): add the settings sections`

### Task 2: Split General into four panes

**Files:**
- Modify: `Sources/MacCommander/Settings/GeneralSettings.swift` (keeps: new-window folder, default file name, "Show in Finder", Full Disk Access; keeps `WindowReader`/`WindowBox` and `chooseFolder()`)
- Create: `Sources/MacCommander/Settings/AppearanceSettings.swift`: `struct AppearanceSettings: View` with "Show checkbox column", "Show hidden files", "Enable dual-pane mode" + its caption. Named after macSCP's pane; `ViewSettings` is already a Core type.
- Create: `Sources/MacCommander/Settings/TerminalSettings.swift`: `struct TerminalSettings: View` with the "Terminal app:" picker, moving `installedTerminals`, `terminalApp` and `isInstalled` with it.
- Create: `Sources/MacCommander/Settings/ShortcutsSettings.swift`: `struct ShortcutsSettings: View` with the "Global hotkey" recorder, its warning, `hotKeyFailedState`, `recordHotKey(_:)` and `clearHotKey()`.

**Interfaces:**
- Consumes: the same environment objects as today (`ViewSettingsStore`, `PreferencesStore`, `HotKeyCenter`, `OpenRequestRouter`), each pane taking only what it reads.
- Produces: the four pane structs above, each `Form { … }.formStyle(.grouped)`, with no fixed width.

- [ ] **Step 1: Move the code.** Cut each control with its helpers into its new file unchanged; update the doc comments so each says what its pane holds.
- [ ] **Step 2: Wire them into the current `TabView` temporarily** (one tab each) so the app builds and every pane can be checked before the layout changes.
- [ ] **Step 3: Run `scripts/test.sh`.** Expected: all pass, no warnings about unused members.
- [ ] **Step 4: Build and run** (`scripts/build-app.sh`, open the app, ⌘,). Check that each control still works: toggles change open windows live, "Choose…" opens as a sheet, the hotkey records, the terminal picker lists installed apps.
- [ ] **Step 5: Commit** `refactor(settings): split General into General, View, Terminal and Shortcuts`

### Task 3: Sidebar layout and resizable window

**Files:**
- Modify: `Sources/MacCommander/Settings/SettingsView.swift`
- Create: `Sources/MacCommander/Settings/SettingsWindowAccessor.swift`: an `NSViewRepresentable` that calls back with its window on `viewDidMoveToWindow` and on updates.
- Modify: `Sources/MacCommander/App/MacCommanderApp.swift:45` (the `Settings` scene: add `.windowResizability(.contentMinSize)`)
- Modify: `Sources/MacCommander/Settings/NetworkSettings.swift:29` (`.frame(height: 220)` → `.frame(minHeight: 220)` so the list grows with the window), `TagsSettings.swift:29` (keep `minHeight: 360`, check that it fits the minimum)

**Interfaces:**
- Consumes: `SettingsSection` (Task 1), the four panes (Task 2), `SidebarSettings`, `TagsSettings`, `NetworkSettings`.
- Produces: `SettingsView.frameAutosaveName = "MacCommander.settings"`, `SettingsView.minimumSize: CGSize`, `SettingsView.sidebarColumnWidth: CGFloat = 180`.

- [ ] **Step 1: Build the split view.** `NavigationSplitView` with `List(SettingsSection.allCases, selection:)` of `Label(section.title, systemImage: section.systemImage)`, `.listStyle(.sidebar)`, `.navigationSplitViewColumnWidth(Self.sidebarColumnWidth)`. Detail: `switch selection ?? .general` over the seven panes, `.navigationSplitViewColumnWidth(min: 460, ideal: 500)`. `.navigationSplitViewStyle(.balanced)`. Selection is `@State` starting at `.general`. Remove the temporary tabs and `.frame(width: 520)`. Copy the reason for the fixed sidebar width (layout loop on macOS 26, seen in macSCP) into a comment.
- [ ] **Step 2: Make the window resizable.** On the root: `.frame(minWidth: minimumSize.width, minHeight: minimumSize.height)` and `.background(SettingsWindowAccessor { window in … })`, which inserts `.resizable` into `styleMask` when it is missing, sets `contentMinSize` from `minimumSize`, and sets `setFrameAutosaveName(frameAutosaveName)` only when it differs. Copy the comment saying that `.windowResizability` alone does not make the window draggable (measured in macSCP).
- [ ] **Step 3: Measure the minimum.** Start from `680 × 520`. Build, open each section at that size, and raise the height until the tallest one (expected: General or Tags) fits without clipping. Write the figure and where it came from into the constant's doc comment.
- [ ] **Step 4: Run `scripts/test.sh`.** Expected: all pass.
- [ ] **Step 5: Check every Review Focus item by hand** in the built app, plus light and dark mode. Leave the app open idle for a minute and confirm in Activity Monitor that it stays near 0 % CPU (the layout-loop check macSCP used).
- [ ] **Step 6: Commit** `feat(settings): sidebar layout in a resizable window that keeps its size`
