# MacCommander Plan 1: Foundation Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runnable, signed-capable `MacCommander.app`. It has a sidebar (Favorites and Locations) and a Finder-grade list view (sortable, persistent columns, inline expansion, checkbox column). Navigation works (back/forward/up, path bar, Go to Folder), as do live refresh, Quick Look, and right-click → New Folder / New Empty File with inline rename.

**Architecture:** There are two SwiftPM targets. `MacCommanderCore` is a library with all testable logic: models, loading, settings, navigation, naming, and the `BrowserModel` view model (no AppKit). `MacCommander` is the executable with the SwiftUI shell plus an AppKit `NSOutlineView` file list that is bridged with `NSViewControllerRepresentable`. `scripts/build-app.sh` assembles, signs and (optionally) notarizes the `.app`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing, SwiftPM, macOS 15+.

**Spec:** `docs/superpowers/specs/2026-11-17-maccommander-design.md`

### Roadmap (this plan is 1 of 6, and each later plan is written when the previous one is done)
1. **Foundation browser** (this plan)
2. File operations: copy/cut/paste, duplicate, trash, compress, conflict dialog, progress, undo, drag and drop, Open With, Get Info, Copy Path, Reveal in Finder
3. Archives as folders (bsdtar)
4. Preview panel + Markdown
5. Persistent network shares (NetFS, Keychain, Kerberos/AD)
6. Tags, search, iCloud Drive, Settings window, Full Disk Access onboarding, app icon

## Global Constraints
- macOS 15 (Sequoia) minimum; Swift 6 language mode; no App Sandbox.
- Must build and test with **Command Line Tools only** (no Xcode). Run tests via `scripts/test.sh`. Plain `swift test` fails under CLT because the Swift Testing macro plugin isn't on the default path. XCTest is **not** available, so use Swift Testing (`import Testing`) everywhere.
- Bundle identifier: `dev.dginx.MacCommander`, defined only in `Resources/Info.plist`.
- No third-party dependencies in this plan.
- Never enumerate directories on the main thread; folders with 50,000 items must stay responsive.
- Only list view exists. View settings are **global** and change only through explicit user action. Never write `.DS_Store` or other Finder metadata.
- Git: work on `main`, no worktrees. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- English-only UI strings, written so they can be localized later (`String(localized:)`).

## Review Focus
1. **A folder that can't be read** (permission denied, or a TCC denial on Desktop/Documents) must show an inline "You don't have permission to see the contents of “X”." message, not an empty list or a crash. Pinned in Task 2 and Task 8.
2. **The open folder is deleted, renamed or ejected from outside** → the app navigates to the nearest existing ancestor without crashing. Pinned in Task 4 and Task 8.
3. **Case-only rename** (`readme.md` → `README.md`) on case-insensitive APFS must work. A naive `moveItem` fails because the "destination exists". Pinned in Task 5.
4. **Names with German umlauts, emoji and numbers** sort the way Finder does (`file2` before `file10`, `Ärger` next to `Apfel`, NFD and NFC forms treated as equal). Pinned in Task 3.
5. **Corrupt or outdated stored settings, or a favorite that no longer exists** → defaults are used for the settings, and the missing favorite stays in the sidebar greyed out. Neither crashes, and neither is silently removed. Pinned in Task 3 and Task 7.

---

## File Structure

```
Package.swift
Resources/Info.plist                       bundle metadata + TCC usage strings
scripts/test.sh                            swift test with CLT plugin path
scripts/build-app.sh                       build, bundle, sign, notarize
Sources/MacCommanderCore/
  Model/FileItem.swift                     one file-system entry
  Model/FileColumn.swift                   column enum + titles
  Model/FileSortOrder.swift                Finder-style comparison
  Settings/ViewSettings.swift              ViewSettings + ColumnLayout + ViewSettingsStore
  Navigation/NavigationHistory.swift       back/forward stack
  Navigation/PathUtilities.swift           nearestExistingAncestor, pathSegments
  FileSystem/DirectoryLoader.swift         async listing + error mapping
  FileSystem/DirectoryWatcher.swift        live-change notifications
  FileSystem/NameGenerator.swift           "untitled 2.txt" naming
  FileSystem/ItemCreator.swift             new folder / new empty file
  FileSystem/ItemRenamer.swift             validated rename incl. case-only
  Sidebar/FavoritesStore.swift             persisted favorites
  Sidebar/VolumeProvider.swift             local mounted volumes
  Browser/BrowserModel.swift               per-window view model
Sources/MacCommander/
  App/MacCommanderApp.swift                @main, WindowGroup, commands
  App/BrowserCommands.swift                menu bar commands via FocusedValue
  Browser/BrowserWindow.swift              NavigationSplitView + toolbar
  Browser/PathBar.swift                    clickable path segments
  Browser/GoToFolderSheet.swift            ⇧⌘G
  Sidebar/SidebarView.swift                Favorites + Locations
  FileList/FileListView.swift              NSViewControllerRepresentable
  FileList/FileListController.swift        outline view data source/delegate
  FileList/FileOutlineView.swift           key handling, context-menu hit test
  FileList/FileCellViews.swift             name/text/checkbox cells
  FileList/CheckboxHeaderCell.swift        tri-state header checkbox
  FileList/FileContextMenu.swift           item/empty-space menus
  QuickLook/QuickLookController.swift      QLPreviewPanel data source
Tests/MacCommanderCoreTests/
  TestSupport.swift                        temp-directory helper
  (one test file per Core source file, named <Type>Tests.swift)
```

---

### Task 1: Package scaffold, scripts, empty window

**Files:**
- Create: `Package.swift`, `.gitignore`, `Resources/Info.plist`, `scripts/test.sh`, `scripts/build-app.sh`, `Sources/MacCommander/App/MacCommanderApp.swift`, `Sources/MacCommanderCore/MacCommanderCore.swift` (placeholder, deleted in Task 2), `Tests/MacCommanderCoreTests/TestSupport.swift`, `Tests/MacCommanderCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: `TemporaryDirectory` test helper: `final class TemporaryDirectory { let url: URL; init() throws; func file(_ name: String, contents: String = "") throws -> URL; func folder(_ name: String) throws -> URL }`. `deinit` removes the directory.
- Produces: `scripts/test.sh [swift test args…]`, `scripts/build-app.sh [-c debug|release] [--open]`, using the env vars `MC_SIGN_IDENTITY` and `MC_NOTARY_PROFILE`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCommander",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MacCommander", targets: ["MacCommander"])],
    targets: [
        .target(name: "MacCommanderCore"),
        .executableTarget(name: "MacCommander", dependencies: ["MacCommanderCore"]),
        .testTarget(name: "MacCommanderCoreTests", dependencies: ["MacCommanderCore"]),
    ]
)
```

`.gitignore`: `.build/`, `build/`, `.swiftpm/`, `*.xcodeproj`, `.DS_Store`.

- [ ] **Step 2: Write `scripts/test.sh`** (make it executable). If `xcodebuild` is not available, run `swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" "$@"`. Otherwise run `swift test "$@"`. Use `set -euo pipefail`.

- [ ] **Step 3: Write a smoke test plus `TemporaryDirectory`, then run them**

`SmokeTests.swift`: `@Test func temporaryDirectoryCreatesFiles()` creates `a.txt` with contents `"hi"` and `#expect`s that the file exists and its contents equal `"hi"`.
Run: `scripts/test.sh`. Expected: `✔ Test run with 1 test … passed`.

- [ ] **Step 4: Write `Resources/Info.plist`**. Keys: `CFBundleIdentifier` = `dev.dginx.MacCommander`, `CFBundleName`/`CFBundleDisplayName` = `MacCommander`, `CFBundleExecutable` = `MacCommander`, `CFBundlePackageType` = `APPL`, `CFBundleShortVersionString` = `0.1.0`, `CFBundleVersion` = `1`, `LSMinimumSystemVersion` = `15.0`, `NSHighResolutionCapable` = true, `LSApplicationCategoryType` = `public.app-category.productivity`. Usage strings, each with the value `MacCommander needs access to show and manage your files.`: `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`.

- [ ] **Step 5: Write a minimal `MacCommanderApp.swift`**: an `@main struct MacCommanderApp: App` with `WindowGroup { Text("MacCommander") }`.

- [ ] **Step 6: Write `scripts/build-app.sh`.** Steps in order:
  1. `swift build -c $CONFIG` (default `debug`).
  2. Recreate `build/MacCommander.app/Contents/{MacOS,Resources}` and copy in the binary (path from `swift build -c $CONFIG --show-bin-path`) and `Resources/Info.plist`.
  3. Sign with `codesign --force --options runtime --timestamp --sign "$MC_SIGN_IDENTITY"`. If the identity is unset, sign ad hoc with `--sign -` and leave out `--timestamp`.
  4. If `MC_NOTARY_PROFILE` is set **and** the config is release: zip with `ditto -c -k --keepParent` to `build/MacCommander.zip`, run `xcrun notarytool submit … --keychain-profile "$MC_NOTARY_PROFILE" --wait`, then `xcrun stapler staple build/MacCommander.app`.
  5. With `--open`, `open build/MacCommander.app`.

- [ ] **Step 7: Verify**
Run: `scripts/build-app.sh --open`. Expected: a window titled "MacCommander" appears. `codesign -dv build/MacCommander.app` reports `Identifier=dev.dginx.MacCommander`.
Run: `MC_SIGN_IDENTITY="Developer ID Application: Agentur3B GmbH (6RH6HM2A9J)" scripts/build-app.sh -c release`. Expected: `codesign --verify --strict --verbose=2 build/MacCommander.app` prints `valid on disk` and `satisfies its Designated Requirement`. (Notarization is not run in this plan; it is verified when the first release is cut.)

- [ ] **Step 8: Commit** `feat: scaffold package, build and test scripts`

---

### Task 2: FileItem and DirectoryLoader

**Files:**
- Create: `Sources/MacCommanderCore/Model/FileItem.swift`, `Sources/MacCommanderCore/FileSystem/DirectoryLoader.swift`, `Tests/MacCommanderCoreTests/DirectoryLoaderTests.swift`
- Delete: `Sources/MacCommanderCore/MacCommanderCore.swift`

**Interfaces:**
- Produces:
  - `public struct FileItem: Identifiable, Hashable, Sendable { public let url: URL; public var id: URL { url }; public let name: String; public let isDirectory: Bool; public let isPackage: Bool; public let isHidden: Bool; public let size: Int64?; public let dateModified: Date?; public let dateCreated: Date?; public let dateAdded: Date?; public let kind: String; public static func load(_ url: URL) throws -> FileItem }`. `isDirectory` is false for packages such as `.app`, so packages behave like files. `size` is nil for directories. `kind` = `localizedTypeDescription`. `name` = `localizedName`.
  - `public static let resourceKeys: [URLResourceKey]`: every key `load` reads, used for prefetching.
  - `public enum DirectoryLoadError: Error, Equatable, Sendable { case permissionDenied(URL), notFound(URL), notADirectory(URL), other(URL, String) }`, plus `public var message: String`. For `permissionDenied`: `You don't have permission to see the contents of “<name>”.` For `notFound`: `The folder “<name>” can't be found.`
  - `public struct DirectoryLoader: Sendable { public init(); public func contents(of url: URL, includeHidden: Bool) async throws(DirectoryLoadError) -> [FileItem] }`. The work runs off the main actor (a `@concurrent` or nonisolated async function). Results are unsorted.

- [ ] **Step 1: Write failing tests**
  - `listsFilesAndFolders`: a temp dir with `a.txt` (contents "abc") and folder `sub` → 2 items. `a.txt` has `size == 3` and `isDirectory == false`. `sub` has `isDirectory == true` and `size == nil`.
  - `hidesDotFilesUnlessRequested`: `.secret` is missing with `includeHidden: false` and present with `true`.
  - `treatsAppBundleAsFile`: a folder `X.app` with `Contents/Info.plist` → `isPackage == true`, `isDirectory == false`.
  - `permissionDeniedIsMapped`: a folder with mode `000` → throws `.permissionDenied(url)`. Restore the mode with `defer`.
  - `missingFolderIsNotFound`: a nonexistent path → `.notFound`.
  - `loadsTenThousandItemsQuickly`: create 10,000 empty files → returns 10,000 items in < 3 s (`ContinuousClock`).

- [ ] **Step 2: Run** `scripts/test.sh --filter DirectoryLoaderTests` → FAIL (types not defined).
- [ ] **Step 3: Implement** `FileItem.load` with `url.resourceValues(forKeys:)`, and `DirectoryLoader.contents` with `FileManager.contentsOfDirectory(at:includingPropertiesForKeys: FileItem.resourceKeys, options: includeHidden ? [] : [.skipsHiddenFiles])`. Map `CocoaError` codes: `.fileReadNoPermission` → `permissionDenied`, `.fileReadNoSuchFile` → `notFound`. Map POSIX `ENOTDIR` → `notADirectory`. Skip entries whose `FileItem.load` fails (they were deleted mid-listing) instead of failing the whole folder.
- [ ] **Step 4: Run** `scripts/test.sh --filter DirectoryLoaderTests` → PASS.
- [ ] **Step 5: Commit** `feat(core): FileItem and async DirectoryLoader`

---

### Task 3: Columns, sorting, view settings

**Files:**
- Create: `Sources/MacCommanderCore/Model/FileColumn.swift`, `Sources/MacCommanderCore/Model/FileSortOrder.swift`, `Sources/MacCommanderCore/Settings/ViewSettings.swift`, `Tests/MacCommanderCoreTests/FileSortOrderTests.swift`, `Tests/MacCommanderCoreTests/ViewSettingsStoreTests.swift`

**Interfaces:**
- Consumes: `FileItem` (Task 2).
- Produces:
  - `public enum FileColumn: String, CaseIterable, Codable, Sendable { case name, dateModified, dateCreated, dateAdded, size, kind, tags; public var title: String }`. Titles: Name, Date Modified, Date Created, Date Added, Size, Kind, Tags. (`tags` gets content in Plan 6; until then the column exists but is empty.)
  - `public struct FileSortOrder: Codable, Equatable, Sendable { public var column: FileColumn; public var ascending: Bool; public var foldersOnTop: Bool; public static let `default` = FileSortOrder(column: .name, ascending: true, foldersOnTop: false); public func sorted(_ items: [FileItem]) -> [FileItem] }`
  - `public struct ColumnState: Codable, Equatable, Sendable { public var column: FileColumn; public var width: Double; public var isVisible: Bool }`
  - `public struct ColumnLayout: Codable, Equatable, Sendable { public var columns: [ColumnState]; public static let `default`: ColumnLayout }`. Default order and widths: name 280 ✓, dateModified 170 ✓, size 80 ✓, kind 140 ✓, tags 90 ✓, dateCreated 170 ✗, dateAdded 170 ✗. `init(from:)` repairs the data: unknown columns are dropped, and missing columns are appended from the default.
  - `public struct ViewSettings: Codable, Equatable, Sendable { public var columnLayout = ColumnLayout.default; public var sortOrder = FileSortOrder.default; public var showHiddenFiles = false; public var showCheckboxColumn = true }`
  - `@MainActor @Observable public final class ViewSettingsStore { public init(defaults: UserDefaults = .standard); public var settings: ViewSettings }`. The setter persists JSON under the key `viewSettings.v1`. Undecodable data → `ViewSettings()`, and the stored value is **left untouched** until the next explicit change.

- [ ] **Step 1: Write failing tests**
  - `sortsNaturally`: names `["file10", "file2", "File1"]` by name ascending → `["File1", "file2", "file10"]`.
  - `sortsUmlautsWithBaseLetter`: `["Zebra", "Ärger", "Apfel"]` → `["Apfel", "Ärger", "Zebra"]`.
  - `nfdAndNfcCompareEqualAndTieBreakStable`: `"Mu\u{0308}ller"` and `"Müller"` sort next to each other, and a repeated sort gives the same order (tie broken by `url.path`).
  - `descendingReverses`, `sizeSortPutsFoldersAsZero` (nil size sorts as 0), `foldersOnTopGroupsFolders`.
  - `settingsRoundTrip`: change `showHiddenFiles` and the width of `name` → a new store on the same `UserDefaults(suiteName:)` reads back equal settings.
  - `corruptDataFallsBackToDefaults`: store `Data("garbage".utf8)` under `viewSettings.v1` → `settings == ViewSettings()`, and the raw stored data is unchanged.
  - `layoutRepairsMissingColumns`: decode JSON containing only `name` → all 7 columns are present, with `name` first.
- [ ] **Step 2: Run** `scripts/test.sh --filter "FileSortOrderTests|ViewSettingsStoreTests"` → FAIL.
- [ ] **Step 3: Implement.** Name comparison uses `localizedStandardCompare`. Other columns compare by value, falling back to the name comparison on ties.
- [ ] **Step 4: Run** the same command → PASS.
- [ ] **Step 5: Commit** `feat(core): columns, Finder-style sorting, persistent view settings`

---

### Task 4: Navigation history and path utilities

**Files:**
- Create: `Sources/MacCommanderCore/Navigation/NavigationHistory.swift`, `Sources/MacCommanderCore/Navigation/PathUtilities.swift`, `Tests/MacCommanderCoreTests/NavigationHistoryTests.swift`, `Tests/MacCommanderCoreTests/PathUtilitiesTests.swift`

**Interfaces:**
- Produces:
  - `public struct NavigationHistory: Equatable, Sendable { public private(set) var current: URL; public init(start: URL); public var canGoBack: Bool; public var canGoForward: Bool; public mutating func visit(_ url: URL); public mutating func goBack() -> URL?; public mutating func goForward() -> URL?; public mutating func replaceCurrent(with url: URL) }`
  - `public enum PathUtilities { public static func nearestExistingAncestor(of url: URL, fileManager: FileManager = .default) -> URL; public static func segments(of url: URL) -> [URL] }`. `segments(/Users/d/Docs)` = `[/, /Users, /Users/d, /Users/d/Docs]`.

- [ ] **Step 1: Write failing tests**: `visitClearsForwardStack`; `visitingCurrentIsNoOp` (`canGoBack` stays false); `backThenForwardRestores`; `replaceCurrentKeepsStacks`; `nearestAncestorSkipsDeletedFolders` (temp `a/b/c`, delete `b` → returns `a`); `nearestAncestorOfRootIsRoot`; `segmentsOfPath`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "NavigationHistoryTests|PathUtilitiesTests"` → FAIL.
- [ ] **Step 3: Implement.** Compare URLs by `standardizedFileURL`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): navigation history and path utilities`

---

### Task 5: Naming, creating, renaming

**Files:**
- Create: `Sources/MacCommanderCore/FileSystem/NameGenerator.swift`, `Sources/MacCommanderCore/FileSystem/ItemCreator.swift`, `Sources/MacCommanderCore/FileSystem/ItemRenamer.swift`, tests `NameGeneratorTests.swift`, `ItemCreatorTests.swift`, `ItemRenamerTests.swift`

**Interfaces:**
- Produces:
  - `public enum NameGenerator { public static func uniqueName(base: String, pathExtension: String?, in directory: URL, fileManager: FileManager = .default) -> String }`. Pattern: `untitled.txt`, `untitled 2.txt`, `untitled 3.txt`, … and `untitled folder`, `untitled folder 2`, …. It checks the file system directly, so hidden files count too.
  - `public enum ItemCreator { public static func createFolder(in directory: URL) throws -> URL; public static func createEmptyFile(in directory: URL) throws -> URL }`. Base names: `untitled folder`, and `untitled` + `txt`. Plan 6 makes these configurable.
  - `public enum RenameError: Error, Equatable { case emptyName, invalidCharacter, nameTaken(String), underlying(String) }`, each with `public var message: String`. For `nameTaken`: `The name “X” is already taken. Please choose a different name.`
  - `public enum ItemRenamer { public static func rename(_ url: URL, to newName: String, fileManager: FileManager = .default) throws(RenameError) -> URL }`. It trims whitespace. Empty → `.emptyName`. A name containing `/` or `:` → `.invalidCharacter`. The same name → returns `url` unchanged. If only the case differs → a two-step move via a unique temporary sibling name (`.<name>.mc-rename-<uuid>`). If another item exists → `.nameTaken`.

- [ ] **Step 1: Write failing tests**: `firstNameIsPlain`; `skipsTakenNames` (with `untitled.txt` and `untitled 2.txt` present → `untitled 3.txt`); `hiddenFileCountsAsTaken` (`.untitled` hidden, base `.untitled` → `.untitled 2`); `createFolderTwice` → `untitled folder` and `untitled folder 2` exist; `createEmptyFileIsZeroBytes`; `renameBasic`; `renameCaseOnly` (`readme.md` → `README.md`: the directory listing contains exactly `README.md`); `renameRejectsEmptyAndSlash`; `renameRejectsExisting` (→ `.nameTaken("b.txt")`, and the source is still present); `renameSameNameIsNoOp`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "NameGeneratorTests|ItemCreatorTests|ItemRenamerTests"` → FAIL.
- [ ] **Step 3: Implement** with `FileManager.createDirectory(withIntermediateDirectories: false)`, `FileManager.createFile(atPath:contents: Data())`, and `moveItem`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): unique naming, new folder/file, safe rename`

---

### Task 6: DirectoryWatcher

**Files:**
- Create: `Sources/MacCommanderCore/FileSystem/DirectoryWatcher.swift`, `Tests/MacCommanderCoreTests/DirectoryWatcherTests.swift`

**Interfaces:**
- Produces: `public final class DirectoryWatcher: @unchecked Sendable { public init?(url: URL, debounce: Duration = .milliseconds(200), onChange: @escaping @Sendable () -> Void); public func cancel() }`. It wraps a `DispatchSource.makeFileSystemObjectSource` on an `O_EVTONLY` fd watching `[.write, .rename, .delete, .link]`. It debounces, and `cancel()` closes the fd. `init` returns nil if the path can't be opened, for example on unsupported network file systems; callers then rely on manual refresh. **The `onChange` callback fires on a background queue.**

- [ ] **Step 1: Write failing tests**: `firesOnFileCreation` (create a file → callback within 2 s, using `confirmation` + `AsyncStream` or a polling loop); `debouncesBursts` (create 20 files quickly → fewer than 5 callbacks within 1 s); `noCallbackAfterCancel`; `nilForMissingPath`.
- [ ] **Step 2: Run** `scripts/test.sh --filter DirectoryWatcherTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): debounced DirectoryWatcher`

---

### Task 7: Favorites and volumes

**Files:**
- Create: `Sources/MacCommanderCore/Sidebar/FavoritesStore.swift`, `Sources/MacCommanderCore/Sidebar/VolumeProvider.swift`, tests `FavoritesStoreTests.swift`, `VolumeProviderTests.swift`

**Interfaces:**
- Produces:
  - `public struct SidebarLocation: Identifiable, Hashable, Sendable { public let url: URL; public var id: URL { url }; public let name: String; public let exists: Bool }`
  - `@MainActor @Observable public final class FavoritesStore { public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default); public private(set) var favorites: [SidebarLocation]; public func add(_ url: URL, at index: Int? = nil); public func remove(_ url: URL); public func move(fromOffsets: IndexSet, toOffset: Int); public func refreshExistence() }`. It stores an array of path strings under `favorites.v1`. When that key is absent, the defaults are the home folder, `~/Desktop`, `~/Documents`, `~/Downloads` and `/Applications`. Adding a URL that's already in the list moves it to the new position instead of duplicating it. A favorite that no longer exists stays in the list with `exists == false`.
  - `public struct VolumeInfo: Identifiable, Hashable, Sendable { public let url: URL; public var id: URL { url }; public let name: String; public let isEjectable: Bool; public let isBoot: Bool }`
  - `public enum VolumeProvider { public static func localVolumes() -> [VolumeInfo]; public static let didChangeNotifications: [Notification.Name] }`. It returns `mountedVolumeURLs(… options: [.skipHiddenVolumes])` filtered to `volumeIsLocal == true`, with the boot volume first. The notifications are `NSWorkspace.didMountNotification`, `didUnmountNotification` and `didRenameVolumeNotification`; the UI observes these. Core may `import AppKit` (needed for these names and for `NSWorkspace.open` in Task 8).

- [ ] **Step 1: Write failing tests**: `defaultsWhenEmpty` (5 entries, the first being the home directory); `addRemovePersist` (a new store on the same suite sees the changes); `addExistingMovesInsteadOfDuplicating`; `missingFavoriteKeptWithExistsFalse` (add a temp folder, delete it, `refreshExistence()` → still listed, `exists == false`); `bootVolumeFirst` (`localVolumes().first?.isBoot == true`, and its URL is `/`).
- [ ] **Step 2: Run** `scripts/test.sh --filter "FavoritesStoreTests|VolumeProviderTests"` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): favorites store and local volumes`

---

### Task 8: BrowserModel

**Files:**
- Create: `Sources/MacCommanderCore/Browser/BrowserModel.swift`, `Tests/MacCommanderCoreTests/BrowserModelTests.swift`

**Interfaces:**
- Consumes: `DirectoryLoader`, `DirectoryLoadError`, `FileItem`, `NavigationHistory`, `PathUtilities`, `ViewSettingsStore`, `DirectoryWatcher`, `ItemCreator`, `ItemRenamer`, `RenameError`.
- Produces: `@MainActor @Observable public final class BrowserModel`, with:
  - `public init(start: URL, settings: ViewSettingsStore, loader: DirectoryLoader = DirectoryLoader())`
  - state: `public private(set) var history: NavigationHistory`, `public var currentURL: URL { history.current }`, `public private(set) var items: [FileItem]` (already sorted by `settings.settings.sortOrder` and filtered by hidden-files), `public private(set) var loadError: DirectoryLoadError?`, `public private(set) var isLoading: Bool`, `public var selection: Set<URL>`, `public var pendingRename: URL?` (set after a create; the list starts inline editing for it, then sets it back to nil).
  - actions: `public func navigate(to url: URL) async`, `public func goBack() async`, `public func goForward() async`, `public func goUp() async`, `public func reload() async`, `public func open(_ item: FileItem) async` (a directory navigates; anything else goes to `NSWorkspace.shared.open`, injected as `opener: @MainActor (URL) -> Void` in `init` with default `{ NSWorkspace.shared.open($0) }`), `public func children(of url: URL) async throws(DirectoryLoadError) -> [FileItem]` (for inline expansion; same sorting and filtering), `public func createFolder(in directory: URL? = nil) async throws -> URL`, `public func createEmptyFile(in directory: URL? = nil) async throws -> URL` (both select the new item and set `pendingRename`), `public func rename(_ url: URL, to name: String) async throws(RenameError) -> URL`.
  - behavior: `navigate` to a non-directory or a missing path does nothing and returns without error. The model starts a `DirectoryWatcher` for `currentURL` and reloads on change (hopping to the main actor). On reload, if `currentURL` no longer exists, it calls `history.replaceCurrent(with: PathUtilities.nearestExistingAncestor(of:))` and loads that. Selection entries that disappear are removed. A `loadError` is cleared by a successful load. Changing `settings` (sort, hidden) re-sorts and re-filters **without** reloading from disk; hidden files force a reload, because the loader filters them.

- [ ] **Step 1: Write failing tests**: `navigateLoadsSortedItems`; `goBackAndForward`; `goUpFromSubfolder`; `permissionDeniedSetsLoadError` (folder with mode 000 → `loadError == .permissionDenied`, `items` empty); `deletedCurrentFolderFallsBackToAncestor` (navigate into `a/b`, delete `b`, `await reload()` → `currentURL == a`); `createEmptyFileSelectsAndRequestsRename`; `externalChangeTriggersReload` (create a file from outside → it appears in `items` within 2 s); `toggleHiddenShowsDotFiles`; `openFileCallsOpener` (injected opener records the URL).
- [ ] **Step 2: Run** `scripts/test.sh --filter BrowserModelTests` → FAIL.
- [ ] **Step 3: Implement.** Use a load generation counter so a slow load for an old folder can't overwrite a newer one.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(core): BrowserModel view model`

---

### Task 9: Window shell: sidebar, toolbar, path bar, Go to Folder

**Files:**
- Create: `Sources/MacCommander/Browser/BrowserWindow.swift`, `Sources/MacCommander/Browser/PathBar.swift`, `Sources/MacCommander/Browser/GoToFolderSheet.swift`, `Sources/MacCommander/Sidebar/SidebarView.swift`, `Sources/MacCommander/App/BrowserCommands.swift`
- Modify: `Sources/MacCommander/App/MacCommanderApp.swift`

**Interfaces:**
- Consumes: `BrowserModel`, `FavoritesStore`, `VolumeProvider`, `ViewSettingsStore`, `PathUtilities.segments`.
- Produces: `struct BrowserWindow: View` (owns a `BrowserModel` per window, publishes it as `.focusedSceneValue(\.browserModel, model)`), and `extension FocusedValues { var browserModel: BrowserModel? }`. `MacCommanderApp` owns one shared `ViewSettingsStore` and one `FavoritesStore` and passes them in through the environment.

Behavior to implement:
- `NavigationSplitView`. Sidebar sections are **Favorites** and **Locations**, each row an SF Symbol plus the name. A missing favorite is greyed out, and clicking it shows an alert: `“X” can't be found. Remove it from Favorites?` with Remove / Cancel. Right-click → Remove from Sidebar. Drag a folder from the list onto Favorites → add. Ejectable volumes show an eject button that calls `NSWorkspace.shared.unmountAndEjectDevice(at:)`.
- Detail area: a placeholder `Text` for the file list (replaced in Task 10) plus `PathBar` at the bottom. Its segments are clickable, with icons from `NSWorkspace.shared.icon(forFile:)`.
- Toolbar: back/forward buttons (disabled based on `canGoBack`/`canGoForward`), a "new folder" button, a "toggle hidden files" button. The window title is the current folder's display name.
- Menu commands in `BrowserCommands`:
  - **Go**: Back ⌘[, Forward ⌘], Enclosing Folder ⌘↑, Go to Folder… ⇧⌘G, Home ⇧⌘H, Desktop ⇧⌘D, Downloads ⌥⌘L, Applications ⇧⌘A.
  - **File**: New Folder ⇧⌘N, New Empty File ⌥⌘N.
  - **View**: Show Hidden Files ⇧⌘. (toggles `settings.showHiddenFiles`), Show Checkbox Column (toggle).
- `GoToFolderSheet`: a text field that expands `~`. Return navigates. An invalid path shows `The folder can't be found.` under the field and keeps the sheet open.
- Window state: `@SceneStorage("currentFolderPath")` restores each window's last folder at launch, falling back to the home folder if it's missing. ⌘N opens a new window at the home folder. Native window tabs work, because `WindowGroup` supports them by default.

- [ ] **Step 1: Implement the views and commands listed above.**
- [ ] **Step 2: Verify the build:** `swift build` → `Build complete!`, with no warnings in our sources.
- [ ] **Step 3: Verify manually:** run `scripts/build-app.sh --open` and check:
  - clicking Favorites and Locations changes the window title and the path bar;
  - ⌘[ and ⌘] work, ⌘↑ works, and ⇧⌘G with `~/Downloads` works;
  - quitting and relaunching restores the folder;
  - removing Desktop from the sidebar persists across relaunch.
- [ ] **Step 4: Commit** `feat: window shell with sidebar, toolbar, path bar, go menu`

---

### Task 10: File list (NSOutlineView) with persistent columns

**Files:**
- Create: `Sources/MacCommander/FileList/FileListView.swift`, `Sources/MacCommander/FileList/FileListController.swift`, `Sources/MacCommander/FileList/FileOutlineView.swift`, `Sources/MacCommander/FileList/FileCellViews.swift`, `Sources/MacCommander/FileList/CheckboxHeaderCell.swift`
- Modify: `Sources/MacCommander/Browser/BrowserWindow.swift` (replace the placeholder)

**Interfaces:**
- Consumes: `BrowserModel` (`items`, `selection`, `children(of:)`, `open(_:)`, `loadError`), `ViewSettingsStore` (`columnLayout`, `sortOrder`, `showCheckboxColumn`), `FileColumn`, `ColumnLayout`.
- Produces: `struct FileListView: NSViewControllerRepresentable { let model: BrowserModel; let settings: ViewSettingsStore }`; `final class FileListController: NSViewController`, `final class FileOutlineView: NSOutlineView`. Later plans (2, 3, 6) add to these classes; keep the data source keyed by `FileItem.url`.

Behavior to implement:
- Outline items are `FileItem`. Folders are expandable: on expansion, call `model.children(of:)` and cache the result per URL. The cache is cleared on reload, but the expanded state is restored by URL after a reload. ← and → collapse and expand (the `NSOutlineView` default).
- Columns follow `ColumnLayout`, with a leading checkbox column (identifier `checkbox`, width 24, not resizable, not movable, hidden when `showCheckboxColumn == false`). Right-clicking the header shows a menu with every `FileColumn` except Name (which is always visible), each with a checkmark. Resizing (`columnDidResize`), moving (`columnDidMove`), and show/hide write back to `settings.settings.columnLayout`. Clicking a header sets `sortOrder` (clicking the same column again toggles direction). The header shows a sort indicator.
- Cells: Name = file icon (`NSWorkspace.shared.icon(forFile:)`, 16 pt, loaded lazily) + name. Date columns use `Date.FormatStyle` with date `.abbreviated` and time `.shortened`; "Today"/"Yesterday" relative formatting like Finder is a nice-to-have, not required. Size uses `ByteCountFormatter` with `.file`, and `--` for folders. Kind is the localized type. Hidden files are drawn at 50% opacity.
- **Checkbox column (spec 2.2.2):** each row's checkbox reflects `selectedRowIndexes`. Clicking a row's checkbox toggles only that row in the selection (`selectRowIndexes(_:byExtendingSelection: true)` / `deselectRow`), like ⌘-click. `CheckboxHeaderCell` draws a tri-state checkbox (`.on` when all rows are selected, `.mixed` when some are, `.off` when none). Clicking it selects all or deselects all.
- Selection is two-way synced with `model.selection` (set of URLs). Restore it by URL after a reload.
- Double-click and ⌘↓ → `model.open(item)`. ⌘↑ → `goUp`. Type-to-select uses the name (`outlineView(_:typeSelectStringFor:item:)`).
- When `model.loadError != nil`: hide the outline and show a centered `ContentUnavailableView`-style message with `loadError.message`. A permission error also gets a button, **Open Privacy Settings**, which opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- Updates: when `model.items` changes, apply it with a diff (`beginUpdates`, insert/remove by URL identity), or `reloadData()` while preserving the scroll position, selection and expansion. No flicker on live refresh.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify the build:** `swift build` → `Build complete!`.
- [ ] **Step 3: Verify manually** (`scripts/build-app.sh --open`):
  - in `~/`, columns show and sort, and clicking Size twice reverses the order;
  - resizing Name, hiding Kind and showing Date Created all survive a relaunch;
  - folders expand inline;
  - checkbox clicks add to the selection without clearing it, the header checkbox shows mixed and all states, and turning off the checkbox column in the View menu hides it;
  - `touch ~/Desktop/x.txt` in Terminal makes the file appear within about 1 s without the list jumping;
  - a folder with mode 000 shows the permission message;
  - create a test folder with 50,000 files (`mkdir /tmp/big && cd /tmp/big && seq 50000 | xargs touch`), open it, and the UI stays responsive while it loads.
- [ ] **Step 4: Commit** `feat: NSOutlineView file list with persistent columns and checkbox selection`

---

### Task 11: Context menus, new items, inline rename, Quick Look

**Files:**
- Create: `Sources/MacCommander/FileList/FileContextMenu.swift`, `Sources/MacCommander/QuickLook/QuickLookController.swift`
- Modify: `Sources/MacCommander/FileList/FileOutlineView.swift`, `Sources/MacCommander/FileList/FileListController.swift`, `Sources/MacCommander/FileList/FileCellViews.swift`

**Interfaces:**
- Consumes: `BrowserModel.createFolder(in:)`, `createEmptyFile(in:)`, `rename(_:to:)`, `pendingRename`, `open(_:)`, `RenameError.message`.
- Produces: `enum FileContextMenu { static func forEmptySpace(model:settings:) -> NSMenu; static func forItems(_ items: [FileItem], model:settings:) -> NSMenu }`. Plans 2, 3 and 6 append items to these menus. `final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate`.

Behavior to implement:
- `FileOutlineView.menu(for:)`: a right-click on empty space (`row(at:) == -1`) deselects everything and returns `forEmptySpace`. A right-click on an unselected row selects only that row. A right-click on a selected row keeps the whole selection. Both of those return `forItems`.
- **Empty-space menu (spec 2.2.3):** New Folder, New Empty File, ─, Sort By ▸ (each column, with a checkmark on the current one), Show Hidden Files (checkmark), Show Checkbox Column (checkmark).
- **Item menu (this plan):** Open, Quick Look “name” (or “N items”), Rename (single item only), ─, New Folder, New Empty File. When exactly one folder is the target, both of these create inside **that** folder and expand it. Plans 2, 3 and 6 append the remaining actions.
- **Inline rename:** Return on a single selected row, or the menu, starts editing the name cell. The text before the extension is preselected, like Finder. Return/blur commits through `model.rename`, and Escape cancels. On `RenameError`, show an `NSAlert` with `error.message`, then go back to editing. When `model.pendingRename` matches a URL that is now visible, scroll to it, start editing, and clear `pendingRename`.
- **Quick Look:** Space toggles `QLPreviewPanel.shared()` for the current selection. The panel follows arrow-key selection changes, and the controller is the panel's data source while the list is the first responder (`acceptsPreviewPanelControl`).

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify the build:** `swift build` → `Build complete!`, and `scripts/test.sh` passes everything.
- [ ] **Step 3: Verify manually** (`scripts/build-app.sh --open`):
  - right-clicking empty space shows New Folder / New Empty File;
  - New Empty File twice → `untitled.txt` and `untitled 2.txt`, each starting in rename mode with `untitled` preselected;
  - renaming to an existing name shows the alert;
  - renaming `readme.md` → `README.md` works;
  - right-clicking a folder → New Folder creates it inside and expands it;
  - Space opens Quick Look, and arrow keys update it;
  - Return renames;
  - double-clicking a `.txt` file opens it in TextEdit.
- [ ] **Step 4: Commit** `feat: context menus, new folder/file, inline rename, Quick Look`

---

## Done when
- `scripts/test.sh` passes, and every Core test from Tasks 1 to 8 is green.
- The manual checklists in Tasks 9 to 11 pass on the user's Mac.
- A release build signed with the Developer ID passes `codesign --verify --strict`.
