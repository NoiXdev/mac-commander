# Row Size Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Row size" setting (Compact / Default / Large) that sets the file list's row height and icon size.

**Architecture:** Core gets a `RowSize` enum with its metrics, stored in `ViewSettings`. The app's `FileListController.applySettings()` applies the row height and icon size; `FileIconProvider` caches icons per size; Settings ▸ View gets a picker.

**Tech Stack:** Swift 6, AppKit (`NSOutlineView`), SwiftUI Settings, Swift Testing, `L10n` string tables.

**Spec:** `docs/superpowers/specs/2026-11-24-row-size-design.md`

## Global Constraints

- Compact: row 20 pt, icon 16 pt. Default: row 24 pt, icon 16 pt. Large: row 36 pt, icon 32 pt. Text stays 13 pt.
- Default is `.regular` ("Default"), which must be exactly today's list (24 pt / 16 pt).
- Stored in `ViewSettings` (key `rowSize`, lenient decoding): a missing or unknown value reads as `.regular`.
- A change applies live in every open list, keeping selection, expanded folders and scroll position.
- Strings in en/de/fr/pl via `L10n`, no raw user-visible strings (`RawStringGuardTests`, `SourceKeyTests`, `LocalizationCatalogTests` must pass):
  - en "Row size" · "Compact" / "Default" / "Large"
  - de "Zeilenhöhe" · "Kompakt" / "Standard" / "Groß"
  - fr "Hauteur des lignes" · "Compacte" / "Standard" / "Grande"
  - pl "Wysokość wierszy" · "Kompaktowa" / "Standardowa" / "Duża"
- No commits during execution (the user commits on request); Conventional Commits without scope when they are made.

## Review Focus

1. Switching to Large and back in a folder with expanded subfolders and a selection: selection, expansion and scroll position survive; no row keeps the old height.
2. Icons after switching size: no stretched 16 pt bitmap in a 32 pt slot, and the file's own icon (not only the type placeholder) appears at the new size for visible rows.
3. Rows being renamed (inline editor) or with tag dots and cloud status on Large: everything stays vertically centered, nothing clips.
4. Settings saved by the previous build (no `rowSize` key) and a garbage value (`"huge"`): both read as `.regular` — pinned in Task 1.
5. Two windows open, both in dual-pane: one change updates all four lists.

---

### Task 1: `RowSize` in Core

**Files:**
- Create: `Sources/MacCommanderCore/Settings/RowSize.swift`
- Modify: `Sources/MacCommanderCore/Settings/ViewSettings.swift` (property, `CodingKeys`, lenient `init(from:)`)
- Test: `Tests/MacCommanderCoreTests/RowSizeTests.swift`, `Tests/MacCommanderCoreTests/ViewSettingsStoreTests.swift`

**Interfaces:**
- Produces: `public enum RowSize: String, Codable, CaseIterable, Sendable { case compact, regular, large }` with `public var rowHeight: Double` and `public var iconSize: Double`; `ViewSettings.rowSize: RowSize` (default `.regular`).

- [ ] **Step 1: Write the failing tests.**
  - `RowSizeTests.metrics`: compact → (20, 16), regular → (24, 16), large → (36, 32) for `(rowHeight, iconSize)`.
  - `RowSizeTests.allCasesInOrder`: `RowSize.allCases == [.compact, .regular, .large]` (the picker's order).
  - `ViewSettingsStoreTests.rowSizeDefaultsToRegular`: `ViewSettings().rowSize == .regular`.
  - `ViewSettingsStoreTests.rowSizeRoundTrips`: store `.large`, reload from the same defaults → `.large`.
  - `ViewSettingsStoreTests.missingRowSizeReadsAsRegular`: decode JSON of an encoded `ViewSettings` with the `rowSize` key removed → `.regular`, other fields kept.
  - `ViewSettingsStoreTests.unknownRowSizeReadsAsRegular`: same with `"rowSize": "huge"` → `.regular`, other fields kept (e.g. `showHiddenFiles: true` survives).
- [ ] **Step 2: Run** `scripts/test.sh --filter 'RowSizeTests|ViewSettingsStoreTests'`. Expected: a compile failure.
- [ ] **Step 3: Implement** `RowSize` and the `ViewSettings` field, decoded like `showCheckboxColumn`.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all pass.

### Task 2: Apply the row size in the list, Settings picker, strings

**Files:**
- Modify: `Sources/MacCommander/FileList/FileListController+Columns.swift` (`applySettings()`)
- Modify: `Sources/MacCommander/FileList/FileListController+Outline.swift` (`viewFor` icon size, icon loading)
- Modify: `Sources/MacCommander/FileList/FileCellViews.swift` (`FileNameCellView` icon constraints; `FileIconProvider` per-size cache)
- Modify: `Sources/MacCommander/Settings/AppearanceSettings.swift`
- Modify: `Sources/MacCommanderCore/Resources/{en,de,fr,pl}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `RowSize`, `ViewSettings.rowSize` (Task 1).

- [ ] **Step 1: `FileIconProvider`** takes the size per call: `placeholder(for item: FileItem, size: CGFloat) -> NSImage`, `cachedFileIcon(for url: URL, size: CGFloat) -> NSImage?`, `loadFileIcons(for urls: [URL], size: CGFloat) async -> [URL: NSImage]`. Type and file icons are cached per (size, key); copy before resizing, as today.
- [ ] **Step 2: `FileNameCellView`** gets `func setIconSize(_ size: CGFloat)`, which updates the icon's width and height constraints (kept as stored constraints) only when they differ.
- [ ] **Step 3: `applySettings()`** sets `outlineView.rowHeight` from `settings.settings.rowSize.rowHeight` when it differs, then refreshes the visible rows' cells (icon size and image) without `reloadData()`, so selection, expansion and scroll position stay. `viewFor` uses the current size for new cells and for icon loading; a file icon that finishes loading for an old size is not shown at the new size.
- [ ] **Step 4: Settings ▸ View:** a `Picker` "Row size" as the first row of the first section, options in `RowSize.allCases` order. Keys: `settings.view.rowSize`, `settings.view.rowSize.compact`, `settings.view.rowSize.regular`, `settings.view.rowSize.large`, with the Global Constraints' texts in all four tables.
- [ ] **Step 5: Run** `swift build` and `scripts/test.sh`. Expected: a clean build and all tests pass.
- [ ] **Step 6: Hand check (for the user, listed in the report):** `scripts/build-app.sh`, open a folder with an expanded subfolder and a selection, switch Compact → Large → Default in Settings ▸ View with the window visible; check the Review Focus items 1–3 and 5, and the picker in German.
