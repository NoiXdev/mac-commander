# MacCommander — Design (v1)

Date: 2026-11-17
Status: Draft for approval

## 1. Intent

MacCommander is a native macOS file manager meant to replace Finder for daily use. The name references Total Commander; a dual-pane mode is planned for later, but **v1 is a single-pane "real Finder clone"** that fixes specific Finder annoyances and adds a few power features.

Why: Finder keeps getting in the way of the user's daily work:
- it does not reliably remember the view style (user always wants list view; Finder sometimes switches back to icons),
- previews are weak (no rendered Markdown),
- archives can only be extracted as a whole, not browsed or extracted file-by-file,
- multi-selection requires ⌘-click (no checkboxes),
- no "New Empty File" in the context menu,
- network shares disappear when switching networks (office ↔ home) and must be re-added manually; the user wants Windows-Explorer-style persistent shares that simply show as disconnected.

Success: the user can use MacCommander instead of Finder for a full working day without falling back to Finder for anything on the day-one list below.

## 2. Goals (v1)

### 2.1 Finder baseline (must work on day one)
- **Window**: single pane: sidebar, toolbar, file list, optional preview panel. Multiple windows (⌘N) and native window tabs (⌘T via system window tabbing).
- **Sidebar sections**:
  - *Favorites*: user-editable (drag folders in, remove via context menu, reorder). Defaults: Home, Desktop, Documents, Downloads, Applications.
  - *iCloud Drive*: `~/Library/Mobile Documents/com~apple~CloudDocs`.
  - *Locations*: the boot volume and mounted local/external volumes, each with an eject button where applicable.
  - *Network*: saved shares with connection status (see 2.2.6).
  - *Tags*: tags in use; clicking a tag shows all files with that tag.
- **Navigation**: back/forward (⌘[ / ⌘]), enclosing folder (⌘↑), open (⌘↓), clickable path bar with segments, "Go to Folder…" (⇧⌘G), "Connect to Server…" (⌘K).
- **File list** (list view; see 2.2.1): columns Name, Date Modified, Size, Kind, Tags; optional Date Created, Date Added. Show/hide via right-click on the header; reorder by dragging; resize; sort by clicking the header. Folders can be expanded inline with a disclosure triangle (→ / ← keys like Finder). Folder sizes show "--".
- **Keyboard**: Finder conventions: Return = rename, ⌘O / ⌘↓ / double-click = open, Space = Quick Look, ⌘⌫ = Move to Trash, ⌘C / ⌘V / ⌥⌘V (move), ⌘D = duplicate, ⌘A select all, type-to-select, ⇧⌘N new folder, ⇧⌘. toggles hidden files.
- **File operations**: copy, cut/move, paste, duplicate, rename (inline), move to Trash, compress to .zip, open with default app, "Open With" submenu. Long operations show progress and can be cancelled. Name conflicts show a dialog: Replace / Keep Both / Skip / Stop, with "Apply to all". Undo (⌘Z) for rename, move, new folder/file, duplicate, and move to Trash (put back).
- **Drag and drop**: within the list, onto sidebar items, to/from Finder and other apps. Default is move on the same volume and copy across volumes; ⌥ forces copy.
- **Quick Look**: Space opens the system Quick Look panel for the selection.
- **Search**: a search field in the toolbar searches the **current folder and its subfolders** by name (Spotlight-backed, with a fallback to direct enumeration for non-indexed locations such as network shares). Results are shown in the same list with a "Location" column.
- **Tags**: tag dots shown in the Name/Tags column; set or remove tags via the context menu (standard Finder tag colors plus custom names). Uses the system tag metadata, so tags stay compatible with Finder.
- **iCloud Drive**: show a status icon for items not downloaded locally; opening such an item triggers the download.
- **Get Info** (⌘I): a simple info panel with name, kind, size (folders computed on demand), created/modified dates, full path, and tags. Read-only in v1, apart from tags.
- **Context menu on items**: Open, Open With ▸, Quick Look, Rename, Duplicate, Copy, Cut, Paste, Move to Trash, Compress, Tags ▸, Get Info, Copy Path, Reveal in Finder.

### 2.2 MacCommander extensions

#### 2.2.1 View style that never changes on its own
- v1 has **only a list view**. There is no icon view to fall back to.
- Column layout (visible columns, order, widths), sort column/direction, and the hidden-files toggle are stored **globally** and apply to every folder. Nothing resets them except an explicit user action.
- Each window remembers its last folder and restores it on relaunch.

#### 2.2.2 Checkbox selection
- The list has a leading checkbox column (can be hidden in Settings).
- The checkboxes **mirror the normal selection**. They are not a separate "marked" set. Clicking a checkbox toggles that one item without clearing the rest, like ⌘-click. Click, ⇧-click and ⌘-click on rows behave as usual and update the checkboxes.
- The header checkbox selects or deselects everything in the current view (tri-state when the selection is partial).

#### 2.2.3 New Folder / New Empty File from the context menu
- Right-click on empty space in the list shows: **New Folder**, **New Empty File**, Paste, Sort By ▸, Show Hidden Files, Get Info (for the current folder).
- New Folder creates "untitled folder" (then "untitled folder 2", …) and New Empty File creates "untitled.txt" (then "untitled 2.txt", …). The item is selected and opens straight into inline rename, so the user types the real name and extension.
- Both actions are also available when right-clicking a folder (creating inside it) and in the File menu.

#### 2.2.4 Better previews
- A toggleable **preview panel** on the right (⇧⌘P) shows the selected item.
- **Markdown** (`.md`, `.markdown`) is rendered (GitHub-flavored: headings, lists, tables, code blocks, task lists, links, images relative to the file) and follows light/dark mode. There is a toggle between rendered and source.
- Everything else uses the system Quick Look preview inside the panel.
- The preview architecture must make it easy to add more custom renderers later (for example syntax-highlighted code, JSON, CSV as a table).

#### 2.2.5 Archives as folders
- Double-click (or ⌘↓) on a **pure archive** **opens it like a folder**: the path bar shows `… › assets.zip › images`, back/forward work, and folders inside the archive can be expanded inline.
- *(Builder's call)* Which files are archives is decided by a **fixed extension list**, not by file content: `zip, tar, tgz, tar.gz, tbz, tbz2, tar.bz2, txz, tar.xz, 7z, rar`. Files that are zips inside (`.docx`, `.xlsx`, `.pages`, `.key`, `.epub`, `.jar`, `.ipa`, `.app`) and system containers (`.pkg`, `.iso`, `.dmg`) keep their **normal open action** (Word, Installer, mounting, …). For any file bsdtar can read, the context menu offers **"Browse Contents"** to open it as a folder anyway. v1 has no per-type setting.
- *(Builder's call)* Format support is **checked when the app runs**: on first use per format, the app tests with bsdtar whether the format can be read. Formats that fail on the current macOS (for example rar or 7z on an older version) fall back to the normal open action, and "Browse Contents" is hidden for them.
- Archives are **read-only** in v1. Available actions:
  - **Extract** the selected items: via context menu to "the folder containing the archive" or "Choose…", or by dragging them out of the list onto a folder, the sidebar, the Desktop or Finder.
  - **Extract All…**
  - **Quick Look / preview** on an entry (the entry is extracted to a temporary folder first).
  - **Open** an entry with its default app (also via a temporary folder).
- Encrypted archives prompt for a password (not stored).
- Context menu on an archive file: Open (browse), Extract All Here, Open with Archive Utility, plus the normal item actions.

#### 2.2.6 Persistent network shares (Explorer-style)
- Connecting to a share via ⌘K (`smb://`, `afp://`, `nfs://`, `https://`/WebDAV) **saves it permanently** in the sidebar's Network section. The password is stored in the macOS Keychain (only if the user chooses "Remember").
- Shares mounted outside MacCommander (Finder, login items) are detected, and the app asks once: "Remember this share?"
- Each saved share always shows one of three states:
  - 🟢 **Connected**: mounted and browsable.
  - ⚪ **Available**: the server can be reached but the share isn't mounted. Clicking it mounts silently with the saved credentials, then navigates there.
  - 🔴 **Unreachable**: the server can't be reached. Shown with a disconnected icon. Clicking it shows a clear message ("office-nas can't be reached from this network") with a Retry button. No cryptic system dialog.
- Reachability is rechecked on launch, whenever the network changes (path monitor), and every 60 s for unreachable shares (a short TCP connect to the protocol port).
- **Auto-reconnect** is a per-share setting, on by default: an Available share with auto-reconnect is mounted automatically.
- *(Builder's call)* **Credentials**: mounts use the system Keychain, so passwords Finder already saved for a server are reused. Mounts are attempted **without UI** first. If that fails because credentials are missing or rejected:
  - auto-reconnect skips the share quietly; it stays ⚪ with a small key badge ("sign-in needed"),
  - clicking the share opens MacCommander's own sign-in sheet (user, password, "Remember in Keychain"),
  - Edit… offers a "Connect as Guest" option.
  This is a badge on the Available state, not a fourth state.
- **Two sign-in types must work** (user's setup: office shares on Windows Active Directory, and a UGREEN NAS at home with a local username and password):
  - **Active Directory**: when the Mac has a valid Kerberos ticket (from a domain-bound Mac, the company's Kerberos SSO extension, Ticket Viewer or `kinit`), the share mounts with it and never asks for a password. *(Builder's call)* If there is no ticket or it has expired, the sign-in sheet accepts a domain account (`DOMAIN\user` or `user@domain`) plus password, which uses SMB's NTLM fallback. Getting new Kerberos tickets from inside MacCommander is **not** in v1.
  - **Username/password** (for example a home NAS): stored in the Keychain as described above.
  - Each saved share remembers how it last authenticated (Kerberos, saved password, or guest) and tries that method first.
- If a share drops while its folder is open, the list shows a "Disconnected" placeholder with a Reconnect button instead of an error. Back/forward history is kept.
- Context menu: Connect, Disconnect, Edit… (URL, display name, user, auto-reconnect), Remove.
- Saved shares persist across launches and network changes until the user removes them.

### 2.3 Settings
A Settings window (⌘,) with: show the checkbox column, show hidden files, default new-file name, default folder for new windows, edit sidebar sections (show/hide), and the network-share list (same actions as the context menu).

## 3. Non-goals (v1)
- Dual-pane / Total Commander mode (planned next).
- Icon, column, and gallery views.
- Writing to archives (add, delete, rename inside an archive), and creating formats other than zip.
- Cloud providers other than iCloud Drive (Dropbox and Google Drive still work as normal folders under `~/Library/CloudStorage`, but get no special integration).
- Replacing Finder as the system default. "Reveal in Finder" from other apps and the Desktop stay Finder's job.
- Editable Get Info (permissions, "Open with" defaults).
- Smart folders / saved searches, and searching file contents.
- App Store distribution and App Sandbox.
- CI / GitHub Actions workflows. The user will add these later.
- Localization (v1 is English only, but strings are kept localizable).

## 4. Anti-goals (failure even if it "works")
- The view style or column layout changes without the user doing it.
- A saved network share disappears or needs re-adding after a network change.
- Data loss: deletes must go to the Trash (no permanent delete in v1). Moves across volumes copy first and delete the source only after the copy succeeds. Conflicts never overwrite silently.
- Sluggishness: opening a folder with 50,000 items must stay responsive (incremental loading, no main-thread enumeration). Unreachable network paths must never block the UI.
- Fighting Finder: tags and labels must stay compatible with Finder, and the app must not write `.DS_Store` view settings or other Finder-specific metadata.

## 5. Constraints
- Native app: Swift 6, macOS 15 (Sequoia) minimum.
- Distribution: public GitHub Releases, signed with a **Developer ID** certificate, **notarized** and stapled, with the hardened runtime. No App Store and no sandbox.
- Built with Swift Package Manager and a local script. Full Xcode is not installed on the dev machine, so the build must work with Command Line Tools only. The package should still open in Xcode if it's installed later.
- No CI in scope.
- Third-party dependencies are allowed but kept minimal. Archives use the system `bsdtar`, with no bundled archive library.
- Git: the repo lives at `~/mac-commander`, default branch `main`; feature branches are OK, worktrees are not.
- Privacy (TCC): the app accesses Desktop, Documents, Downloads, removable and network volumes, so it needs the matching `NS…UsageDescription` strings. On first launch, a short onboarding hint recommends granting Full Disk Access (optional).

## 6. Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | **SwiftUI app shell + AppKit `NSOutlineView` for the file list** | Native Finder-grade list (performance with huge folders, inline disclosure, checkbox column, drag and drop, type-to-select, header menus); SwiftUI keeps the sidebar, preview, settings and dialogs quick to build. Cost: bridging code between the two frameworks. |
| B | SwiftUI only (`Table`) | Least code, but `Table` struggles with very large folders, inline expansion, fine-grained selection and drag and drop. The core features would hit those limits and need a rewrite. |
| C | AppKit only | Maximum control, but a lot more code for the simple parts and slower iteration. |

Excluded: Electron, Tauri and other web-based shells, because the app must be native.

The user picked **A**.

## 7. Decided parts of the "how"
- **UI split**: SwiftUI for the window scaffold (`NavigationSplitView` or equivalent), sidebar, toolbar, preview panel, settings and sheets. AppKit `NSOutlineView`, wrapped for SwiftUI, for the file list, including archive and search results.
- **One list, many sources**: the file list shows items from a common "item source" abstraction with three implementations: local or mounted folder, archive contents, and search results. Navigation, path bar and history work the same for all three.
- **Archives**: list with `bsdtar -tv` (or an equivalent stable listing mode) and extract selected entries with `bsdtar -x -C <dest> <entries…>`, run as a child process off the main thread. The builder is free to choose the parsing approach.
- **Markdown**: parse with Apple's `swift-markdown` (cmark-gfm), render to HTML, and show it in a `WKWebView` with a light/dark stylesheet.
- **Network shares**: mount with the `NetFS` framework (asynchronous mount with credentials), check reachability with `Network.framework` (path monitor plus a short TCP probe), store passwords in the Keychain, and save the share list as JSON in `~/Library/Application Support/MacCommander/`.
- **Settings and view state**: `UserDefaults`.
- **Folder watching**: the open folder refreshes live when files change on disk (FSEvents or a dispatch source). Network folders that can't be watched refresh on focus or via manual refresh (⌘R).
- **Build output**: `scripts/build-app.sh` builds a release binary with SwiftPM, assembles `MacCommander.app` (Info.plist, `.icns` made with `iconutil`), signs it with the Developer ID identity (passed as a parameter or environment variable), and optionally notarizes and staples it with `xcrun notarytool` (using a keychain profile name from the environment). An unsigned or ad-hoc-signed build must also work for local development.
- **Tests**: unit tests (XCTest or Swift Testing) for the non-UI logic: archive listing parsing, share state machine and persistence, conflict-resolution naming ("untitled 2.txt", "Keep Both" names), the undo stack for file operations, and settings persistence. The UI is verified manually.

## 8. Left to the builder
- Module and target layout, type names, and the exact bridging pattern between SwiftUI and AppKit.
- Icons and artwork (SF Symbols where possible; the app icon can be a placeholder).
- The Markdown stylesheet.
- How the tag list in the sidebar is collected (for example a Spotlight query for tags in use plus Finder's standard colors).
- How Spotlight and fallback search are combined.
- Internal concurrency design (actors/tasks), as long as the anti-goal on sluggishness holds.
- The order in which features are built, as long as each step leaves a runnable app.
