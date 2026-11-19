# Default File Browser and Global Hotkey (short design)

Date: 2026-11-19 · Status: approved · Builds on the v1 spec and the dual-pane design.

**Intent:** make MacCommander the place files and folders land, instead of the Finder, as far as macOS allows, and reach it from anywhere with one key.

**Spike findings (2026-11-19, on this Mac):**
- With the global default `NSFileViewer` set to the app's bundle id, `NSWorkspace.activateFileViewerSelecting` (used by other apps' "Show in Finder"), `selectFile(_:inFileViewerRootedAtPath:)` and `open -R` all reach the app as a standard open-documents event (`aevt/odoc`) carrying every item. In SwiftUI and AppKit that arrives through `application(_:open:)`, both when the app is already running and when it is launched cold.
- If any of the URLs doesn't exist, the system drops the whole reveal silently. That is outside our control.
- macOS refuses to change the default handler for folders: `LSSetDefaultRoleHandlerForContentType` and `NSWorkspace.setDefaultApplication(at:toOpen: .folder)` both return paramErr (-50) for `public.folder`. Making folders open in MacCommander system-wide is therefore **not possible**, and is not part of this design.
- The app must be registered with LaunchServices, which happens for any app outside `/private/tmp`. Otherwise the system logs "Finder replacement … not found".

**Behavior:**
- **Settings ▸ General:** a toggle **"Use MacCommander for “Show in Finder”"**, off by default.
  - On: `defaults write -g NSFileViewer dev.noix.MacCommander` (via `CFPreferencesSetValue` in the any-application domain, current user).
  - Off: the key is removed, so the Finder takes over again.
  - The toggle shows the actual system value when Settings opens, so a change made elsewhere (another app or Terminal) is reflected.
- **Our own "Reveal in Finder"** keeps going to the Finder. It opens the Finder explicitly (by bundle id `com.apple.finder`) instead of calling `activateFileViewerSelecting`, which would otherwise loop back into MacCommander.
- **Opening folders:** Info.plist declares `public.folder` (role Viewer, rank Alternate), so these work:
  - dropping folders on the Dock icon;
  - `open -a MacCommander <folder>`;
  - Open With ▸ MacCommander.
- **Every incoming open request opens a new window** (the user's choice):
  - A single folder: the new window shows its contents.
  - Otherwise: the items are grouped by parent folder, and each group gets one new window at that folder with its items selected.
  - *Builder's call:* a "Show in Finder" on a single folder also opens that folder rather than selecting it in its parent, because both requests arrive the same way.
  - Windows open in single-pane mode; the dual-pane setting isn't applied to them.
  - Items inside archives never arrive this way, since only real paths are sent.
- **Global hotkey:**
  - **Setting:** Settings ▸ General gets "Global hotkey", a shortcut recorder that is empty (off) by default. The shortcut is stored in `Preferences`. A shortcut needs at least one of ⌘, ⌥ or ⌃, and Clear turns it off.
  - **Action:** pressing it activates MacCommander and brings its windows to the front. If no browser window is open, it opens a new one, which starts at the "new window" folder from Preferences.
  - **How:** registered with Carbon `RegisterEventHotKey`, which needs no Accessibility or Input Monitoring permission.
  - **Conflicts:** if registration fails (the shortcut is taken by the system or another app), Settings shows "This shortcut is already in use" and the setting is not saved.

**Approaches considered:**
- **NSFileViewer, a folder document type, and a Carbon hotkey (chosen):** the only documented-enough paths. Tested in the spike.
- **Finder Sync extension:** it can only add items inside the Finder; it can't redirect anything. Rejected.
- **A Services menu entry:** it has to be picked by hand every time, so it's not a replacement. Rejected.
- **Watching the Finder and taking over its windows:** fragile, and needs Accessibility permission. Rejected.
- **Where incoming items go:** new window (user's pick), front window, or new tab (the app has no tabs). The user chose a new window each time.

**Non-goals:**
- Folders opened system-wide (Spotlight, `open <folder>`, Dock stacks) — macOS blocks it.
- Open and Save dialogs, the desktop, and the Finder in the Dock.
- Quitting or hiding the Finder.
- Window tabs.
- A hotkey that toggles (hides the app on a second press).

**Left to the builder:**
- The shortcut recorder's look. It may be a small custom control, since there's no third-party dependency.
- Where the Apple Event and open-URL handling lives: the existing `AppDelegate`.
- How a new window gets its start folder and selection, e.g. a pending-open queue that `BrowserWindow.onAppear` consumes, or `openWindow` with a value.
- Exact wording of the Settings labels.
