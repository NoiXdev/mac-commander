# Tabs in browser windows (short design)

Date: 2026-11-24 · Status: approved in conversation · Branch: `improvements`

**Intent:** the user wants tabs "like in the Finder": ⌘T opens a new tab in the current window, and a folder can be opened in a new tab. The user approved this design as proposed.

**Today:** every browser window is a SwiftUI `WindowGroup(id: BrowserWindow.sceneID)` window. macOS already lets the user merge such windows into tabs (Window ▸ Merge All Windows, the tab bar's "+"), but there is no New Tab command and no way to open a folder in a tab. `OpenRequestRouter` opens new windows (`openNewWindow()`), and a fresh `BrowserWindow` takes one pending `OpenRequest(folder:selection:)`; without a request it starts at Settings ▸ General ▸ "New windows open".

## Approaches

- **macOS window tabs** (each tab is a full browser window in the window's tab group): tab bar, dragging tabs out, merging, ⌃Tab / ⇧⌘[ ], and state restoration come from the system, and the behavior matches the Finder. **Picked.**
- An own tab bar inside the window: rebuilds what macOS already provides, and keyboard and restore behavior would differ from the Finder.
- Tabs per pane (Total Commander style): changes the window model; a project of its own.

## Behavior

- **File ▸ New Tab (⌘T)**, directly under New Window. Opens a new tab in the tab group of the frontmost browser window, at the "New windows open" folder, like ⌘N. With no browser window open, it opens a window. It works whatever the user's "Prefer tabs when opening documents" system setting is.
- **Open in New Tab** in the context menu of folders in the file list (and of folders in the sidebar, where its menu already offers folder actions). With several folders selected, each opens in its own tab, in selection order, and the last one is frontmost.
- **⌘-double-click** on a folder opens it in a new tab. On files, ⌘ changes nothing: they open as before.
- "Folder" means a folder the list navigates into on double-click: not a package (an app or bundle opens as before), not an entry inside an archive (no tab item there), not an archive file.
- A new tab is a full browser window: its own folder, history, dual-pane state and preview.
- **Strings:** all four languages, in macOS wording, verified against the system's strings: de "Neuer Tab", "In neuem Tab öffnen"; fr "Nouvel onglet", "Ouvrir dans un nouvel onglet"; pl "Nowa karta", "Otwórz w nowej karcie".

## Non-goals

- Tabs per pane.
- "Open in New Window".
- Dragging a folder onto the tab bar.
- A setting to open folders in tabs by default.

## Left to the builder

How a new window joins the anchor window's tab group (e.g. `addTabbedWindow(_:ordered:)` once the new `NSWindow` exists), how the router remembers the anchor, and the menu wiring.

## Docs

`guide/browsing.md` (tabs), the context-menu sections it links, and `reference/keyboard-shortcuts.md` (⌘T, ⌘-double-click) on docs.noix.dev change with this feature.
