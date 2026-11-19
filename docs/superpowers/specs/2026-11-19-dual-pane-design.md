# MacCommander — Dual-Pane Mode (Design)

Date: 2026-11-19
Status: Draft for approval
Builds on: `2026-11-17-maccommander-design.md` (v1, complete). Everything there still applies unless this document says otherwise.

## 1. Intent

The user copies files between a NAS and local folders, and between two local folders, many times a day. Today that takes two windows arranged side by side. Dual-pane mode puts two folder lists in one window, Total Commander style: pick files on one side, send them to the folder open on the other.

Success: a NAS↔local or local↔local copy is "select, F5, Enter" in one window, with the same safety as today's copies (progress, cancel, conflict dialog, undo), and a slow or dead NAS never freezes the other pane.

## 2. Goals

### 2.1 Modes
- **Dual-pane is opt-in.** Settings ▸ General gets a checkbox "Enable dual-pane mode", **off by default**. While it is off, the app looks and behaves exactly like v1: no ⌘2 / Dual Pane menu item, no toolbar button, no Swap Panes / Same Folder / Copy to Other Pane / Move to Other Pane, and F5/F6 (and ⌘5/⌘6) do nothing.
- Turning the setting off while dual-pane windows are open switches them all to single-pane (keeping each one's active pane), as if ⌘1 had been pressed in each. Turning it back on does not switch any window to dual-pane by itself.
- Each window is either **single-pane** (exactly today's window) or **dual-pane**. View ▸ Single Pane (**⌘1**) and View ▸ Dual Pane (**⌘2**), plus a toolbar button that toggles between them.
- The mode is per window and is restored on relaunch, together with both panes' folders.
- Turning dual-pane on for the first time in a window opens the second pane on the same folder as the first. Later, it reopens on the folder it last showed (if that folder is gone, the same fallback as a window's restored folder today).
- Turning dual-pane off keeps the **active** pane as the window's only pane. The other pane's folder is remembered for next time; its history, search and selection are dropped.
- Native window tabs (⌘T) are unchanged: each tab is a whole window, single or dual.

### 2.2 Layout
```
┌──────────┬─────────────────────────────┬─────────────────────────────┐
│ Sidebar  │ ▌Name           Size  Date  │  Name           Size  Date  │
│          │ ▌ Projects        --  …     │   backup          --  …     │
│ Favorites│ ▌ report.pdf   2 MB   …     │   photos          --  …     │
│ iCloud   │ ▌ notes.md     4 KB   …     │                             │
│ Network  │ ▌                           │                             │
│  🟢 NAS  │ ▌                           │                             │
├──────────┼─────────────────────────────┼─────────────────────────────┤
│          │ ▌Home › Documents           │  NAS › backup               │
└──────────┴─────────────────────────────┴─────────────────────────────┘
   ▌ = active pane
```
- Sidebar on the left (shared), then the two panes split 50/50 with a draggable divider, then the optional preview column on the far right.
- Each pane has its **own path bar** directly under its list, so both locations are always visible. The search-truncation notice ("More than 10,000 results…") also belongs to its pane.
- The operations strip (progress) stays one strip at the bottom of the window, spanning both panes.
- Column layout (visible columns, order, widths), sort order and hidden-files stay **global**, as in v1, so both panes look alike.

### 2.3 Panes
A pane is everything that belongs to one folder view: the file list, its folder state (current folder, Back/Forward history, search or tag view, selection, inline-expanded folders, Disconnected placeholder, archive browsing) and its path bar. The two panes are fully independent: navigating, searching, or a share dropping in one does not affect the other.

### 2.4 The active pane
- Exactly one pane is active in dual-pane mode. Clicking anywhere in a pane (list, empty area, path bar) makes it active.
- **Tab** switches the active pane and moves keyboard focus to its list. While renaming inline or typing in the search field, Tab keeps its normal behaviour.
- The active pane is shown with an accent-colored edge and an emphasized path bar; the inactive pane's selection is drawn in the inactive (gray) style.
- Everything that today targets "the window's list" targets the active pane: the sidebar (clicking an item navigates the active pane, and the sidebar's selection highlight reflects the active pane's folder), Back/Forward, ⌘↑, ⌘↓, ⇧⌘G, the toolbar search field, ⌘I, Quick Look, the preview, all File/Edit/Go menu commands, and the window title.
- The toolbar search field shows the active pane's search text; switching panes switches the text shown. Starting a search searches the active pane's folder.
- In single-pane mode the one pane is always active and no active-pane marking is drawn.

### 2.5 Copy and move between panes
Three ways, all landing in the existing copy/move machinery (FileOperationCenter, progress strip, Cancel, conflict dialog, Undo, per-operation threads):

1. **Keys.** **F5** copies, **F6** moves the active pane's checked/selected items to the other pane's current folder. With nothing selected, the focused row is used; with no focused row, the command does nothing. **⌘5 / ⌘6** do the same, so the commands also work when the Mac's F-keys act as media keys (fn not held). (⌘F5 is not used: macOS reserves it for VoiceOver.)
   A small sheet on the window asks for confirmation:
   - "Copy 3 items to:" / "Move 3 items to:" (one item: "Copy “report.pdf” to:"), followed by the target folder's path in an editable text field, preselected.
   - Enter confirms, Esc cancels. An edited path that doesn't exist or isn't a folder shows an inline error and keeps the sheet open (no folders are created).
   - *(Builder's call)* An edited path is used for this one operation only; the other pane does not navigate there. `~` is expanded; relative paths are refused with the inline error. Undo records the actual destination.
   - *(Builder's call)* The sheet's existence check runs off the main thread (like every other path query) and the sheet stays responsive while it runs; it does **not** check write permission. A read-only target or a share that dropped meanwhile fails in the operation itself and is reported the same way a failed paste is today.
   - *(Builder's call)* For archive entries the sheet says "Extract 3 items to:"; confirming runs the existing extract flow (password prompt included).
2. **Drag and drop** from one pane onto the other pane's list (its folder) or onto a folder row in it, with the same rules as v1: move on the same volume, copy across volumes, ⌥ forces copy.
3. **Context menu**: "Copy to Other Pane" and "Move to Other Pane" on item rows. They open the same confirmation sheet as F5/F6.

Rules:
- Only in dual-pane mode; in single-pane mode F5/F6, ⌘5/⌘6 and the menu items are disabled/hidden.
- The target must be a real folder: if the other pane shows a search, a tag view, an archive or a Disconnected placeholder, the commands are disabled.
- Source inside an archive: **F5 extracts** the selected entries into the other pane's folder (same path as v1's "Extract to…", including password handling). F6 and Move to Other Pane are disabled for archive entries (archives are read-only).
- Source is a search or tag view: allowed; the selected results are copied/moved (they are real files).
- Copying a folder into itself or its own subfolder is refused the same way v1 refuses it for paste/drag.
- *(Builder's call)* Drops within the same pane, and what a drag carries (checked vs. selected items), behave exactly as in v1; a cross-pane drop is just a drop onto another list.
- After a copy/move finishes, both panes update through the existing folder watching; no extra refresh logic.

### 2.6 Extra Total Commander commands
- **F7**: New Folder in the active pane (same as the existing New Folder command).
- **F8**: Move to Trash for the active pane's selection (same as ⌘⌫, with the same undo).
- **Swap Panes** (View menu): exchanges the two panes' folders. Each pane keeps its own history; the swap is a navigation in each pane, so Back undoes it per pane.
- **Same Folder in Other Pane** (View menu): navigates the other pane to the active pane's current folder (real folders only; disabled for search, tag view and archive).
- F7 and F8 also work in single-pane mode and with the dual-pane setting off (they are plain aliases that change nothing visible). Swap and Same Folder are dual-pane only.

### 2.7 Preview
- The preview stays one column at the far right of the window and shows the active pane's selection.
- Its on/off state is stored separately per mode: in dual-pane mode it starts hidden; ⇧⌘P toggles it. Single-pane keeps today's global setting.
- *(Builder's call)* Both states are **global** (one for all single-pane windows, one for all dual-pane windows), alongside today's setting in the view settings, not per window.
- *(Builder's call)* Each pane keeps a minimum width of 200 pt and the preview 240 pt; in dual-pane mode the window's minimum width grows to fit sidebar + two panes. The preview never hides itself automatically.

## 3. Non-goals
- Tabs inside a pane (Total Commander folder tabs).
- Synchronized browsing, folder compare and folder sync.
- A Total Commander button bar / function-key bar at the bottom.
- Vertical (top/bottom) split.
- More than two panes.
- Per-pane column layouts.
- A queue or background list of transfers beyond today's operations strip.

## 4. Constraints
All v1 constraints apply: Swift 6, SwiftPM with Command Line Tools only (no `@State`/`@Entry` macros), tests via `scripts/test.sh`, app via `scripts/build-app.sh`, work on `main`, no worktrees, no sandbox, no CI. Tests must never touch the real Trash or the real Keychain.

## 5. Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | **Extract a "pane" unit** (folder model + file list + path bar) from today's window; a window holds one or two panes, and shared chrome (sidebar, toolbar, search field, menus, preview) acts on the active pane. | Clean separation: every existing feature works per pane without "which list?" checks. Cost: a refactor of `BrowserWindow` and of how menu commands find their target. |
| B | Two linked windows tiled side by side | Exactly the two-window setup the user wants to avoid. Rejected. |
| C | Bolt a second list onto the current window code | Fastest start, but search, Disconnected, archives, rename and Quick Look would all need ad-hoc target checks; the likely bug is a command hitting the wrong pane, i.e. copying in the wrong direction. Rejected. |

## 6. Decided parts of the "how"
- The folder state stays `BrowserModel` (one per pane); the file list stays `FileListView`/`FileListController` (one per pane). Neither needs to know about dual-pane.
- Menu commands and the toolbar find their target through the **active pane's** model (today: the focused window's model).
- Copy/move/extract between panes call the same core operations as paste, drag and "Extract to…".
- Per-window persistence (mode, both folders, active pane, preview state per mode) uses the same scene storage mechanism as today's restored folder.

## 7. Left to the builder
- How the active pane is tracked and published to menus (focused values, a window-level object, etc.).
- How Tab is intercepted without breaking rename, search and type-to-select.
- How function keys are bound (SwiftUI shortcuts vs. key handling in the list).
- Exact visual style of the active-pane marking, within "accent-colored edge, emphasized path bar".
- Divider position persistence (nice to have, not required).
