# Open in Terminal (short design)

Date: 2026-11-19 · Status: draft for approval · Builds on the v1 spec and the dual-pane design.

**Intent:** open a shell in a folder straight from the file list.

**Behavior:**
- **Context menu on items**, labelled "Open in Terminal":
  - A folder opens in itself.
  - A file opens in the folder that contains it.
  - With several items selected, each distinct folder gets one window.
- **Context menu on empty space:** opens the current folder.
- **Search and tag results:** each result opens in its own folder.
- **Inside an archive:** the item is not shown, because archive entries have no real path.
- **Disconnected placeholder:** no menu, as today.
- **Setting:** Settings ▸ General gets "Terminal app: Terminal / iTerm", stored in `Preferences`.
  - It defaults to iTerm when iTerm is installed, otherwise Terminal.
  - iTerm is offered only when it is installed.
  - If the chosen app has been uninstalled, Terminal is used.

**How:** the folder URL is handed to the app with `NSWorkspace.open([folder], withApplicationAt:configuration:)`. Both Terminal and iTerm open a new window with a shell in that folder. This needs no AppleScript and no Automation permission prompt. Folder paths are worked out without file-system access: an item that is a folder uses its own URL, and anything else uses its parent. The open call itself is asynchronous and never blocks the main thread. A failure shows an alert: "Couldn't open Terminal: …".

**Approaches considered:**
- **NSWorkspace open (chosen):** no permission prompts and works the same for both apps.
- **AppleScript `do script "cd …"`:** needs the Automation permission and a separate script per app. Rejected.
- **Settings choice (user's pick)** over a fixed app: the user chose to have the choice.

**Non-goals:**
- A keyboard shortcut.
- A toolbar button.
- Terminals other than Terminal and iTerm.
- Opening a tab instead of a window. Each app decides that through its own settings.

**Left to the builder:** where the menu item sits in the menus (next to Copy Path / Reveal in Finder), and how the app's installed state is detected (`NSWorkspace.urlForApplication(withBundleIdentifier:)`: `com.apple.Terminal`, `com.googlecode.iterm2`).
