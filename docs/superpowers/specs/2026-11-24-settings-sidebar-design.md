# Settings with a sidebar (short design)

Date: 2026-11-24 · Status: approved in conversation · Branch: `improvements`

**Intent:** the Settings window gets the same layout as macSCP's: a list of sections on the left, the selected section on the right, and a window the user can resize freely. Both apps then look and behave alike. The layout also has room for the next feature, a per-extension default app ("Open with").

**Today:** `SettingsView` is a `TabView` with four tabs (General, Sidebar, Tags, Network), fixed at 520 pt wide. General holds most of the options.

**Sections** (the user approved this split):

| Section | Symbol | Content |
|---|---|---|
| General | `gearshape` | Folder new windows open · default name for new files · "Use MacCommander for Show in Finder" · Full Disk Access |
| View | `eye` | Show checkbox column · show hidden files · enable dual-pane mode |
| Terminal | `terminal` | Terminal app picker |
| Shortcuts | `keyboard` | Global hotkey (recorder and its "already in use" warning) |
| Sidebar | `sidebar.left` | As today |
| Tags | `tag` | As today |
| Network | `network` | As today |

Every control keeps its store, its wording and its behavior. Nothing moves to a different store and nothing is renamed. Only the pane it sits in changes.

**Window behavior**, taken from macSCP's `SettingsView`:
- `NavigationSplitView` with a sidebar `List(selection:)` over a `SettingsSection` enum. Each case owns its title and SF Symbol. The detail column is a `switch` over the selection. General is selected when the window opens.
- The sidebar has a fixed width of 180 pt (`navigationSplitViewColumnWidth`). In macSCP, a negotiated sidebar width made SwiftUI spin in a layout loop on macOS 26.
- The detail column is at least 460 pt wide. The window has a minimum size, held in one constant used both for the SwiftUI `.frame(minWidth:minHeight:)` and for the window's `contentMinSize`. The figure is measured on the tallest section and must fit every section without clipping.
- **Resizable:** the `Settings` scene gets `.windowResizability(.contentMinSize)`, and a window accessor inserts `.resizable` into the window's `styleMask` when it is missing. macSCP measured that the scene modifier alone does not make a Settings window draggable.
- **Size is remembered:** `setFrameAutosaveName("MacCommander.settings")`, set once.
- Every section's form uses `.formStyle(.grouped)` and fills the detail column, so a wider window gives the content more room instead of centering it in a fixed box.

**Approaches considered:**
- **Mirror macSCP's `NavigationSplitView` (chosen):** the same look and the same measured fixes, from code that already works.
- **Keep the `TabView` with more tabs and only make it resizable:** gives no sidebar, which is what the user asked for. Rejected.
- **A hand-built `HStack` with a custom list:** loses the native sidebar look and selection handling for no gain. Rejected.

**Non-goals:**
- New settings or changed defaults.
- A "What's new" or "Manage Data" section like macSCP's.
- Section groups such as macSCP's "Protocols". There are only seven flat sections.
- The "Open with" section. It comes with the next feature.

**Left to the builder:**
- Whether to add a "Show in Finder" or Full Disk Access section of its own if General still reads crowded. Default: keep them in General as approved.
- The exact minimum height, measured as described above.
- Where the window-accessor helper lives. The Settings folder is fine, and so is `App/` if other windows will use it.
- The Settings window stays the parent of the folder panel sheet (General's "Choose…") and of Network's sheets and alerts, as today.
