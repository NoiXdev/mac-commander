# MacCommander Plan 6: Tags, Search, iCloud Drive, Settings and App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the v1 spec.
- Finder-compatible **tags**: colored dots, a Tags column, a Tags ▸ context menu, tags in Get Info, and a sidebar Tags section.
- **Search**: the toolbar searches the current folder and its subfolders by name. It uses Spotlight, with direct enumeration for network shares and unindexed volumes, and shows results with a Location column.
- **iCloud Drive**: a sidebar entry, a "not downloaded" icon, and download on open.
- **Settings** window (⌘,), **Full Disk Access** onboarding, and the **app icon**.
- The carry-over items from Plans 1–5.

**Architecture:**
- **Core** gets:
  - `FileTag` and `TagStore`, which read and write Finder's tag extended attribute.
  - `FileItem.tags` and `FileItem.cloudStatus`.
  - A search layer: `SearchQuery`, `SearchPattern` and the `FileSearchEngine` protocol, with Spotlight, enumeration and composite engines.
  - Search state in `BrowserModel`.
  - `PreferencesStore`, using `UserDefaults` in the same pattern as `ViewSettingsStore`.
  - `TagCatalog`, the list of tags in use.
  - `SerialQueueExecutor`, a thread-backed `TaskExecutor` for long file operations.
- **The UI**:
  - Adds the search field, the Location column, tag menus and cells, the sidebar sections, the Settings scene, the launch-alert queue and onboarding.
  - Search results and tag views are an overlay on the current folder, not history entries. See Ruling P6-1.

**Tech Stack:** Swift 6, SwiftPM (Command Line Tools only), SwiftUI + AppKit, Foundation `NSMetadataQuery`, `getxattr`/`setxattr`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-17-maccommander-design.md`. This plan covers §2.1 Sidebar (iCloud Drive, Tags, Network), Search, Tags, iCloud Drive, Get Info tags, the context-menu Tags ▸, §2.3 Settings, §5 TCC onboarding, and §7's `.icns` via `iconutil`.

## Global Constraints

- Swift 6, macOS 15 minimum. Command Line Tools only:
  - Run tests with `scripts/test.sh`. Plain `swift test` lacks the Swift Testing plugin path.
  - The `@State`, `@Entry` and `@Observable`-in-View macros are unavailable in views. Use `State<T>` properties and hand-written `FocusedValueKey`s, as in `BrowserWindow.swift`. `@Observable` on classes works.
- Core logic lives in `MacCommanderCore` and has unit tests (Swift Testing: `@Test`, `#expect`). The UI in `MacCommander` is verified manually.
- **Never block the main thread or the cooperative pool on file-system calls.**
  - Blocking calls go through `PathQueries.run`: a per-call serial queue, so each blocked call gets its own thread.
  - Long operations use the new `SerialQueueExecutor` (Task 1).
  - Unreachable network paths must never block the UI (spec §4).
- **Tags must stay Finder-compatible** (spec §2.1, §4).
  - Tags are stored only in the `com.apple.metadata:_kMDItemUserTags` extended attribute, as a binary plist array of strings `"<name>\n<color>"`.
  - Color numbers: 0 none, 1 gray, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
  - Do not write `.DS_Store` or any other Finder metadata.
- No permanent delete. No silent overwrite.
- **Search matches names only** (spec §3: no content search). Matching ignores case and diacritics and looks for a substring. Scope: the current folder and its subfolders.
- **Settings** use `UserDefaults` (spec §7). The Settings window has:
  - show the checkbox column
  - show hidden files
  - default new-file name (default `untitled.txt`)
  - default folder for new windows (default: home)
  - sidebar sections show/hide
  - the network-share list with Connect, Disconnect, Edit… and Remove…
- **Strings** are English and localizable: `String(localized:)`.
- **Tests must never touch:**
  - the real Trash;
  - the real Keychain, unless `MC_KEYCHAIN_TESTS=1`;
  - the real `UserDefaults.standard`. Use `UserDefaults(suiteName:)` with a UUID and remove the suite afterwards.
  - Spotlight-backed tests must not depend on the index of the developer's machine. Spotlight engines are tested through their pure parts (predicate, mapping); integration goes through fakes.
- **Git:** work on `main`, no worktrees, commit per task. Subagents never create files outside their task's paths.

## Rulings made while planning (each: what — why — cost if wrong)

- **P6-1:** Search and tag results are an overlay on the current folder (`BrowserModel.search`), not history entries.
  - Back (⌘[) while an overlay is shown closes it. Any navigation closes it.
  - Why: history is URL-based and every navigation path is URL-checked. Virtual search URLs would touch all of them.
  - Cost if wrong: Forward can't return to a closed search. The user retypes it.
- **P6-2:** Engine choice.
  - Local volumes use Spotlight. If Spotlight finishes with zero results, enumeration runs as a fallback, for unindexed or excluded folders.
  - Network volumes use enumeration only.
  - Tag views use Spotlight on the local computer.
  - Search is disabled inside archives.
  - Why: the spec leaves the combination to the builder. This catches unindexed drives without double work.
  - Cost if wrong: a partly indexed volume misses unindexed hits.
- **P6-3:** Results are capped at 10,000 items, and the list says "More than 10,000 results; refine your search." Enumeration skips package contents and honors the hidden-files setting.
  - Cost if wrong: deep searches are truncated, and the user is told.
- **P6-4:** Tag colors come from the xattr, which is read only for files whose `tagNamesKey` is non-empty, so untagged files cost nothing extra.
  - Standard tag names come from `NSWorkspace.shared.fileLabels`, which is localized; its index is the color number.
  - Writes go to the xattr directly, with explicit colors.
  - Cost if wrong: a custom tag's color, set only in Finder's registry, shows uncolored until it is set in-app.
- **P6-5:** iCloud download status refreshes through the folder watcher and on reload. There is no per-item progress.
  - Cost if wrong: the cloud icon can lag until the next folder event.
- **P6-6:** Nice-to-have carry-overs deferred past v1:
  - PathQueries per-volume lanes
  - the preview image queue
  - persisting the preview pane width
  - sign-in for a minimized window

  They are recorded in the final report. Only the Markdown scroll position and the Keychain deprecation are done here (Task 12).

## Review Focus

1. **Searching a huge or dead network folder.**
   - The app stays responsive and typing a new query cancels the old one.
   - No stale results ever land after a newer query or navigation.
   - Pinned by `SearchEngineTests.enumerationCancelsAndCaps` and `BrowserModelSearchTests.staleResultsDropped` (Tasks 5–6).
2. **Search text with Spotlight wildcard or quote characters** (`*`, `?`, `"`, `\`, `'`) matches literally. Pinned by `SearchPatternTests.escapesWildcards` (Task 5).
3. **Tag writes keep what they don't understand.**
   - Other tags and entries without a color survive add and remove.
   - A write to a read-only file throws and doesn't crash.
   - Pinned by `TagStoreTests.preservesUnknownEntries` and `TagStoreTests.readOnlyThrows` (Task 3).
4. **An invalid default new-file name** (`""`, `"a/b"`, `"a:b"`, `"."`, `".."`, whitespace-only) is rejected, and creation uses `untitled.txt`. Pinned by `PreferencesTests.invalidNewFileNameFallsBack` (Task 2).
5. **A missing iCloud Drive folder** (not signed in) hides the sidebar row. A missing default new-window folder falls back to home. Pinned by `PreferencesTests.missingWindowFolderFallsBack` (Task 2) and manual check M7.

---

### Task 1: Thread-backed executor for long operations, and the flaky staging test

Carry-over: long operations still run on the cooperative pool, so a dead share destination can tie up its threads. The test `ArchiveExtractorTests.cancelRemovesStaging` is flaky.

**Files:**
- Create: `Sources/MacCommanderCore/System/SerialQueueExecutor.swift`
- Modify:
  - `Sources/MacCommanderCore/Operations/FileOperationCenter.swift`, where each operation's `Task` is created (around line 309)
  - `Sources/MacCommanderCore/FileSystem/FolderSizeCalculator.swift`
  - the undo path in `FileUndoStack.swift`, if it does disk work outside the center
- Test:
  - `Tests/MacCommanderCoreTests/SerialQueueExecutorTests.swift`
  - `Tests/MacCommanderCoreTests/ArchiveExtractorTests.swift:341`

**Interfaces:**
- Produces:
  - `public final class SerialQueueExecutor: TaskExecutor, @unchecked Sendable { public init(label: String) }`. Every job runs on one private serial `DispatchQueue`. Serial queues overcommit, so each executor gets its own thread when a job blocks.
  - `public static func withOwnThread<T: Sendable>(label: String, _ body: @Sendable () async throws -> T) async rethrows -> T` on `SerialQueueExecutor`. It runs `body` under `withTaskExecutorPreference(SerialQueueExecutor(label:))`.
- Consumers: Task 5 (enumeration search).

- [ ] **Step 1: Write the failing tests.**
  - `blockedJobsDontStarvePool`:
    - Start `ProcessInfo.processInfo.activeProcessorCount + 4` tasks. Each calls `SerialQueueExecutor.withOwnThread` and blocks synchronously on one shared `DispatchSemaphore`.
    - Then `#expect` that a plain `Task { 42 }.value` completes within 2 s.
    - Signal the semaphore enough times to release every task.
  - `runsBodyAndReturnsValue`: `#expect(await SerialQueueExecutor.withOwnThread(label: "t") { 7 } == 7)`.
- [ ] **Step 2: Run them.**
  - Command: `scripts/test.sh --filter SerialQueueExecutorTests`
  - Expected: FAIL, because the type is undefined.
- [ ] **Step 3: Implement the executor.**
  - `enqueue(_ job: consuming ExecutorJob)` wraps the job as an `UnownedJob` and calls `queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }`.
- [ ] **Step 4: Route every long operation through `withOwnThread`.**
  - The operations: transfer, trash, compress, extract, folder size and undo/redo.
  - Each operation gets its own label, `"MacCommander op <kind>"`.
  - Calls that are already `@concurrent` stay `@concurrent`, wrapped in the preference.
  - Remove any now-redundant `Task.detached`.
- [ ] **Step 5: Fix `cancelRemovesStaging`.**
  - First find out why it misses the 5 s window. Likely causes: a loaded machine, and a staging folder that appears and disappears between polls.
  - Make it deterministic: use a test hook in `ArchiveExtractor` that fires when staging is created (an internal `static var afterStagingCreatedHook`), or poll with a 30 s deadline.
  - Record the cause in the commit message.
- [ ] **Step 6: Run the full suite.**
  - Run: `scripts/test.sh`, three times in a row.
  - Expected: all pass every time.
- [ ] **Step 7: Commit.** Message: `feat: run long file operations on their own threads; deflake staging test`.

### Task 2: Preferences (default new-file name, new-window folder, sidebar sections)

**Files:**
- Create: `Sources/MacCommanderCore/Settings/Preferences.swift`
- Modify:
  - `Sources/MacCommanderCore/FileSystem/ItemCreator.swift`
  - `Sources/MacCommanderCore/Browser/BrowserModel.swift`: `createEmptyFile`
  - `Sources/MacCommander/App/MacCommanderApp.swift`: create and inject the store
  - `Sources/MacCommander/Browser/BrowserWindow.swift`: `startURL`
- Test: `Tests/MacCommanderCoreTests/PreferencesTests.swift`

**Interfaces:**
- Produces:
  - `public enum SidebarSection: String, CaseIterable, Codable, Sendable { case favorites, iCloud, locations, network, tags }`
  - `public struct Preferences: Codable, Equatable, Sendable`, with fields:
    - `newFileName: String = "untitled.txt"`
    - `newWindowFolderPath: String? = nil`, where nil means home
    - `hiddenSidebarSections: Set<SidebarSection> = []`
    - `didShowFullDiskAccessHint = false`

    Decoding is lenient, field by field, like `ViewSettings`.
  - `public static func isValidFileName(_ name: String) -> Bool` on `Preferences`. False for empty or whitespace-only names, names containing `/` or `:`, `"."` and `".."`.
  - `public var effectiveNewFileName: String` on `Preferences`: `newFileName` when valid, else `"untitled.txt"`.
  - `public func newWindowFolder(exists: (URL) -> Bool) -> URL` on `Preferences`: the folder when set and existing, else home.
  - `@MainActor @Observable public final class PreferencesStore`:
    - `init(defaults: UserDefaults = .standard)`
    - `public var preferences: Preferences`, persisted under the key `"preferences.v1"` in `didSet`
  - `ItemCreator.createEmptyFile(in:named:)`:
    - `named` is split into base and extension at the last `.`, but only when that dot isn't the first character. So `".env"` has no extension, and `"Makefile"` has no extension.
    - It uses `NameGenerator.uniqueName(base:pathExtension:in:)`.
    - The old one-argument form calls it with `"untitled.txt"`.
  - `BrowserModel.createEmptyFile(in:)` reads the name from a new `@ObservationIgnored public var newFileName: @MainActor () -> String = { "untitled.txt" }`. The app wires it to `preferences.effectiveNewFileName`.

- [ ] **Step 1: Write the failing tests.**
  - `defaultsRoundTrip`: a fresh suite store yields `Preferences()`. Setting `newFileName = "notes.md"` persists, and a new store on the same suite reads `"notes.md"`.
  - `lenientDecoding`: stored JSON `{"newFileName": 5, "hiddenSidebarSections": ["tags","bogus"]}` gives `newFileName == "untitled.txt"`.
    - Unknown section values are dropped. Decode the array leniently, like `ColumnLayout`.
  - `invalidNewFileNameFallsBack`: for each of `["", "  ", "a/b", "a:b", ".", ".."]`, `effectiveNewFileName == "untitled.txt"`.
  - `createEmptyFileNamed`: in a temp directory, check these names:
    - `"notes.md"` creates `notes.md`, then `notes 2.md`.
    - `"Makefile"` creates `Makefile`, then `Makefile 2`.
    - `".env"` creates `.env`, then `.env 2`.
  - `missingWindowFolderFallsBack`: `Preferences(newWindowFolderPath: "/nonexistent-\(UUID())").newWindowFolder(exists: { FileManager.default.fileExists(atPath: $0.path) })` returns the home directory.
- [ ] **Step 2: Run them.**
  - Command: `scripts/test.sh --filter PreferencesTests`
  - Expected: FAIL.
- [ ] **Step 3: Implement the Core parts.** `Preferences` needs a memberwise initializer with defaults so the tests can build one.
- [ ] **Step 4: Wire the UI.**
  - `MacCommanderApp` owns `PreferencesStore` and puts it in the environment of every scene.
  - `BrowserWindow`:
    - `startURL` uses `preferences.newWindowFolder` when there is no stored path. The existence check runs off main through `PathQueries.info`: start at home, then navigate once it is known.
    - It sets `model.newFileName`.
- [ ] **Step 5: Run the full suite and build.**
  - Commands: `scripts/test.sh && scripts/build-app.sh`
  - Expected: both pass.
- [ ] **Step 6: Commit.** Message: `feat: preferences store with new-file name and new-window folder`.

### Task 3: Finder tags in Core (`FileTag`, `TagStore`, `FileItem.tags`, `FileItem.cloudStatus`)

**Files:**
- Create:
  - `Sources/MacCommanderCore/Tags/FileTag.swift`
  - `Sources/MacCommanderCore/Tags/TagStore.swift`
- Modify:
  - `Sources/MacCommanderCore/Model/FileItem.swift`
  - `Sources/MacCommanderCore/Model/FileSortOrder.swift`: the `.tags` column
  - archive entries: `ArchiveIndex` builds `FileItem`s, which get empty `tags` and a nil `cloudStatus`
- Test:
  - `Tests/MacCommanderCoreTests/TagStoreTests.swift`
  - `Tests/MacCommanderCoreTests/FileSortOrderTests.swift`

**Interfaces:**
- Produces:
  - `public enum TagColor: Int, CaseIterable, Codable, Sendable { case none = 0, gray, green, purple, blue, yellow, red, orange }`
    - `public static let finderOrder: [TagColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]`
  - `public struct FileTag: Hashable, Codable, Sendable { public let name: String; public let color: TagColor }`
    - Equality and hashing go by `name` only, compared case-insensitively. Finder treats names case-insensitively.
  - `public enum TagStore`:
    - `public static let attributeName = "com.apple.metadata:_kMDItemUserTags"`
    - `public static func decode(_ data: Data) -> [FileTag]`, a pure parser. A string without `"\n"` gets color `.none`, and an unparsable color gets `.none`. Non-string elements are skipped.
    - `public static func encode(_ tags: [FileTag]) -> Data`: a binary plist array of `"name\ncolor"`.
    - `public static func readNow(_ url: URL) -> [FileTag]`: getxattr with `XATTR_NOFOLLOW`. A missing attribute gives `[]`.
    - `public static func writeNow(_ tags: [FileTag], to url: URL) throws`. An empty list removes the attribute.
    - `public static func setTags(_ change: TagChange, on urls: [URL]) async throws`, run through `PathQueries.run`.
      - `public enum TagChange: Sendable { case add(FileTag), remove(FileTag), replace([FileTag]) }`
      - add and remove keep every other entry exactly, unknown ones included.
  - `public enum CloudStatus: Sendable, Hashable { case current, notDownloaded, downloading }`
  - `FileItem`:
    - `public internal(set) var tags: [FileTag] = []`
    - `public internal(set) var cloudStatus: CloudStatus? = nil`
    - `load` adds these keys to `resourceKeys`: `.tagNamesKey`, `.isUbiquitousItemKey`, `.ubiquitousItemDownloadingStatusKey`, `.ubiquitousItemIsDownloadingKey`.
    - `tags` is set from `TagStore.readNow` only when `tagNames` is non-empty. If the xattr is unreadable, it falls back to the names with `.none`.
    - `cloudStatus` is nil unless `isUbiquitousItem`.
  - Sorting by `.tags` compares the joined tag names with `localizedStandardCompare`. Untagged items sort last when ascending.

- [ ] **Step 1: Write the failing tests.**
  - `decodeFinderFormat`: `encode([FileTag(name:"Red",color:.red), FileTag(name:"Work",color:.none)])` round-trips through `decode`. Also: decoding a plist `["Projekt", "Rot\n6", 5]` yields `[Projekt/.none, Rot/.red]`.
  - `readWriteRoundTrip`: in a temp file, `writeNow`, `readNow` and `FileItem.load(url).tags` agree. `writeNow([])` removes the attribute, so `getxattr` returns `ENOATTR`.
  - `preservesUnknownEntries`:
    - The raw xattr is `["Keep\n9", "Blue\n4"]`.
    - `setTags(.add(Red), on:)` gives raw strings exactly `["Keep\n9", "Blue\n4", "Red\n6"]`.
    - So encode keeps an unknown color number verbatim: store the raw color `Int` in a private field. Equality still goes by name.
    - Then `.remove(Blue)` gives `["Keep\n9", "Red\n6"]`.
  - `addIsIdempotentCaseInsensitive`: adding `"red"` to a file tagged `"Red\n6"` changes nothing.
  - `readOnlyThrows`: chmod 0o444 is not enough on macOS. Use `chflags uchg` via `setResourceValue(true, forKey: .isUserImmutableKey)`. Then `#expect(throws:)` on `setTags`, then clear the flag.
  - `untaggedFileHasNoTagsAndNoCloudStatus`.
  - In `FileSortOrderTests`, `sortsByTags`: items tagged `["B"]`, `["A"]` and `[]`, ascending, give A, B, untagged.
- [ ] **Step 2: Run them.**
  - Command: `scripts/test.sh --filter 'TagStoreTests|FileSortOrderTests'`
  - Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite.**
  - Run: `scripts/test.sh`
  - Expected: all pass.
- [ ] **Step 5: Commit.** Message: `feat: Finder-compatible tag storage and cloud status on items`.

### Task 4: Tags in the UI (dots, Tags column, Tags ▸ menu, Get Info)

**Files:**
- Create: `Sources/MacCommander/Tags/TagMenu.swift` and `Sources/MacCommander/Tags/TagDotsView.swift`
- Modify:
  - `Sources/MacCommander/FileList/FileCellViews.swift`
  - `Sources/MacCommander/FileList/FileListController+Outline.swift`
  - `Sources/MacCommander/FileList/FileContextMenu.swift`
  - `Sources/MacCommander/Info/InfoWindow.swift`

**Interfaces:**
- Consumes: `TagStore.setTags`, `FileTag`, `TagColor.finderOrder` (Task 3), and `TagCatalog.shared.tags` from Task 7. Until Task 7 lands, use the standard colors only. Task 7 adds the custom tags.
- Produces:
  - `@MainActor enum TagMenu`:
    - `static func make(for urls: [URL], current: [[FileTag]], window: NSWindow?) -> NSMenuItem`, the "Tags" submenu.
    - `static func standardTags() -> [FileTag]`: the names come from `NSWorkspace.shared.fileLabels[color.rawValue]`, in `finderOrder`.
    - `static func color(_ tagColor: TagColor) -> NSColor`: from `NSWorkspace.shared.fileLabelColors`, with `.none` giving clear.

- [ ] **Step 1: Name cell.** After the name label, show up to 3 overlapping 8 pt color dots, in item tag order and skipping `.none`. Use a `TagDotsView` that draws circles with a 1 pt background-colored ring, like Finder.
- [ ] **Step 2: Tags column.** `FileListFormat.text(.tags)` is the tag names joined with `", "`.
- [ ] **Step 3: The Tags ▸ submenu.** It goes after "Compress" in `forItems` and is hidden inside archives.
  - Items:
    - each standard tag, with a dot image;
    - then the custom tags in use;
    - then "New Tag…": an `NSAlert` with a text field, where an empty name does nothing.
  - State: `.on` when every item has the tag, `.mixed` when some do.
  - Choosing a tag: if every item has it, remove it from all; otherwise add it to all.
  - Errors show `NSAlert(error:)`. The list updates through the folder watcher, plus `model.reload()` for network folders.
- [ ] **Step 4: Get Info.**
  - Load the tags in `ItemInfo.load` with `TagStore.readNow`.
  - Show a "Tags" row: chips with a dot, the name and an ⓧ that removes the tag, plus a "+" menu button using `TagMenu.make`.
  - Edits apply, then reload `ItemInfo`.
- [ ] **Step 5: Build and smoke-test by hand.**
  - Run: `scripts/build-app.sh --open`.
  - Tag a file Red in MacCommander, and Finder shows it red. Tag one in Finder, and MacCommander shows the dot after the folder refreshes.
- [ ] **Step 6: Commit.** Message: `feat: tag dots, Tags column, Tags menu and tags in Get Info`.

### Task 5: Search engines in Core

**Files:**
- Create:
  - `Sources/MacCommanderCore/Search/SearchQuery.swift`
  - `Sources/MacCommanderCore/Search/SearchPattern.swift`
  - `Sources/MacCommanderCore/Search/EnumerationSearch.swift`
  - `Sources/MacCommanderCore/Search/SpotlightSearch.swift`
  - `Sources/MacCommanderCore/Search/CompositeSearch.swift`
- Test:
  - `Tests/MacCommanderCoreTests/SearchPatternTests.swift`
  - `Tests/MacCommanderCoreTests/SearchEngineTests.swift`

**Interfaces:**
- Consumes: `SerialQueueExecutor.withOwnThread` (Task 1), `FileItem.load`, `PathQueries.info(_:).isLocalVolume`.
- Produces:
  - `public enum SearchScope: Hashable, Sendable { case folder(URL), tag(String) }`
  - `public struct SearchQuery: Hashable, Sendable { public var text: String; public var scope: SearchScope }`. For `.tag`, `text` is ignored.
  - `public enum SearchPattern`:
    - `matches(_ name: String, text: String) -> Bool`: `range(of:options:[.caseInsensitive, .diacriticInsensitive])`, with the text trimmed.
    - `likeEscaped(_ text: String) -> String`: escapes `\`, `*` and `?` with a backslash.
  - `public enum SearchUpdate: Sendable, Equatable { case results([FileItem], truncated: Bool), finished }`. `results` carries the full snapshot so far. Updates are emitted at most every 200 ms, and once at the end.
  - `public protocol FileSearchEngine: Sendable { func search(_ query: SearchQuery, includeHidden: Bool) -> AsyncStream<SearchUpdate> }`. Ending the consumer's iteration, or cancelling it, stops the work.
  - `public struct EnumerationSearch: FileSearchEngine`:
    - `init(limit: Int = 10_000)`.
    - It uses `FileManager.enumerator` with `.skipsPackageDescendants`, plus `.skipsHiddenFiles` unless `includeHidden`.
    - It runs inside `withOwnThread` and checks `Task.isCancelled` per entry.
    - For `.tag` it immediately yields `.finished`.
  - `public struct SpotlightSearch: FileSearchEngine`:
    - `static func predicate(for query: SearchQuery) -> NSPredicate`. A folder query is `kMDItemFSName LIKE[cd] "*<escaped>*"`. A tag query is `kMDItemUserTags == "<name>"`, compared case-insensitively with `[c]`.
    - The search scope is the folder's URL for a folder query, and `NSMetadataQueryLocalComputerScope` for a tag query.
    - `NSMetadataQuery` is created, started and stopped on the main actor, and observes gathering, progress and finish notifications.
    - Result paths become `FileItem`s through `PathQueries.run` in batches.
    - Hidden items are dropped unless `includeHidden`.
  - `public struct CompositeSearch: FileSearchEngine`:
    - `init(spotlight: any FileSearchEngine = SpotlightSearch(), enumeration: any FileSearchEngine = EnumerationSearch(), isLocal: @escaping @Sendable (URL) async -> Bool = { await PathQueries.info($0).isLocalVolume })`.
    - Routing follows Ruling P6-2: a local folder goes to Spotlight, and if that finishes with zero results, to enumeration. A non-local folder goes to enumeration. A tag goes to Spotlight.

- [ ] **Step 1: Write the failing tests.**
  - `SearchPatternTests`:
    - `matchesCaseAndDiacriticInsensitive`: `"Résumé.pdf"` matches `"resume"`, and `"Notes"` doesn't match `"x"`.
    - `escapesWildcards`: `likeEscaped("a*b?c\\d")` equals `"a\\*b\\?c\\\\d"`.
    - `predicateForFolderQuery`: the `predicateFormat` of `SpotlightSearch.predicate(for: .init(text: "a*\"b", scope: .folder(tmp)))` contains `kMDItemFSName` and `LIKE[cd]`. Evaluated against `["kMDItemFSName": "xa*\"by"]` it is true, and against `"xaZZby"` it is false.
  - `SearchEngineTests`:
    - `enumerationFindsNestedMatches`: the temp tree `a/Report.txt`, `a/b/report-2.md`, `a/b/other.txt` and `pkg.app/Contents/report.txt` gives exactly the two report files, skipping the package contents.
    - `enumerationHonorsHidden`: `.report` is found only with `includeHidden: true`.
    - `enumerationCancelsAndCaps`:
      - With `limit: 5` over 20 matching files, the last update is `.results(5 items, truncated: true)` followed by `.finished`.
      - Breaking out of the `for await` after the first update returns within 1 s.
    - `compositeFallsBackWhenSpotlightEmpty`: fake engines record their calls. Spotlight yields `[]` and finishes, so enumeration is called and its results stream out.
    - `compositeUsesEnumerationOnNetwork`: with `isLocal` returning false, the spotlight fake is never called.
    - `compositeTagUsesSpotlight`.
- [ ] **Step 2: Run them.**
  - Command: `scripts/test.sh --filter 'SearchPatternTests|SearchEngineTests'`
  - Expected: FAIL.
- [ ] **Step 3: Implement.** No test may start a real `NSMetadataQuery`.
- [ ] **Step 4: Run the full suite.**
  - Run: `scripts/test.sh`
  - Expected: all pass.
- [ ] **Step 5: Commit.** Message: `feat: name search via Spotlight with enumeration fallback`.

### Task 6: Search in `BrowserModel` and the UI (search field, Location column)

**Files:**
- Modify:
  - `Sources/MacCommanderCore/Browser/BrowserModel.swift`
  - `Sources/MacCommanderCore/Model/FileColumn.swift`
  - `Sources/MacCommanderCore/Settings/ViewSettings.swift`
  - `Sources/MacCommanderCore/Model/FileSortOrder.swift`
  - `Sources/MacCommander/Browser/BrowserWindow.swift`
  - `Sources/MacCommander/FileList/FileListController*.swift`
  - `Sources/MacCommander/FileList/FileContextMenu.swift`
  - `Sources/MacCommander/FileList/FileCellViews.swift`
  - `Sources/MacCommander/App/BrowserCommands.swift`
- Test: `Tests/MacCommanderCoreTests/BrowserModelSearchTests.swift`

**Interfaces:**
- Consumes: `FileSearchEngine`, `SearchQuery`, `SearchUpdate` (Task 5).
- Produces:
  - `FileColumn.location`, titled "Location".
    - `ColumnLayout.default` appends `ColumnState(column: .location, width: 200, isVisible: true)`.
    - Lenient decoding already appends it to stored layouts.
    - Sorting by location compares parent paths with `localizedStandardCompare`.
  - `BrowserModel`:
    - `public private(set) var search: SearchQuery?`
    - `public private(set) var searchIsRunning = false`
    - `public private(set) var searchTruncated = false`
    - `public var isSearching: Bool { search != nil }`
    - `public func startSearch(_ text: String) async`. Empty or whitespace text calls `endSearch()`. Otherwise the scope is `.folder(currentURL)`. It is a no-op inside archives.
    - `public func showTag(_ name: String) async`
    - `public func endSearch()`: restores the folder's `items` by running `load()`.
    - A new init parameter `searchEngine: any FileSearchEngine = CompositeSearch()` on both initializers.
  - While searching:
    - `items` are the sorted results and `listedURL` stays the current folder.
    - Watcher reloads don't replace results.
    - Changing the sort re-sorts the results.
    - Every navigation, including `goBack`, `goForward`, `navigate`, `goUp` and `open` of a folder, calls `endSearch()` first.
    - `goBack` while searching only ends the search and doesn't move in history (Ruling P6-1).
    - Each search bumps a generation, so updates from an older search are dropped.

- [ ] **Step 1: Write the failing tests** with a `FakeSearchEngine` that yields scripted updates and records queries.
  - `startSearchShowsResults`: after the updates arrive, `items` equals the sorted fake results and `isSearching` is true.
  - `emptyTextEndsSearch`: `startSearch("  ")` gives `isSearching == false`, and `items` is the folder again.
  - `staleResultsDropped`:
    - The engine's first stream yields late, after a gate. Then `startSearch("b")` yields at once.
    - Opening the gate must not change `items` away from the results for "b".
    - The same holds after `navigate(to:)` mid-search: no results land in the new folder.
  - `backEndsSearchWithoutMovingHistory`: navigate from A to B, search, then `goBack()`. The model is in B and not searching. A second `goBack()` reaches A.
  - `watcherDoesNotClobberResults`: write a file into the current folder during the search, and `items` stays the results.
  - `tagScopeUsesTagQuery`: `showTag("Red")` makes the engine record `.tag("Red")`.
  - `noSearchInArchive`.
- [ ] **Step 2: Run them.**
  - Command: `scripts/test.sh --filter BrowserModelSearchTests`
  - Expected: FAIL.
- [ ] **Step 3: Implement the model.**
- [ ] **Step 4: Build the UI.**
  - **Search field:** `.searchable(text:placement: .toolbar, prompt: "Search")` on the detail view. A `.task(id: text)` waits 250 ms, then calls `startSearch`. Clearing the field ends the search.
  - **⌘F:** Find… in the Edit menu, via `BrowserCommands`, focuses the field. Use `searchFocused` (macOS 15).
  - **Location column:** the list shows it only while `model.isSearching` and the column `isVisible`. It is hidden from the header menu and from Sort By outside search.
    - Cell text: the parent path with the home directory abbreviated to `~`.
  - **Status:** while `searchIsRunning`, the empty or placeholder area shows "Searching…". With no results and finished, it shows "No Results". When `searchTruncated`, a footer line under the list says "More than 10,000 results; refine your search."
  - **The path bar:** while searching, it shows `Searching “<text>” in <folder>` or `Tag: <name>`.
  - **Disabled during search:** New Folder (toolbar and menus) and the empty-space New and Paste items.
  - **Still working during search:** item actions, inline expansion, Quick Look and preview.
  - A tag view shows the tag name in the window title.
- [ ] **Step 5: Run the full suite and build.**
  - Commands: `scripts/test.sh && scripts/build-app.sh`
  - Expected: both pass.
- [ ] **Step 6: Commit.** Message: `feat: search field with results and Location column`.

### Task 7: Sidebar: Tags section, iCloud Drive, Network row when empty, section visibility

Carry-over: the Network section is hidden when empty.

**Files:**
- Create:
  - `Sources/MacCommanderCore/Tags/TagCatalog.swift`
  - `Sources/MacCommander/Sidebar/TagsSection.swift`
- Modify:
  - `Sources/MacCommander/Sidebar/SidebarView.swift`
  - `Sources/MacCommander/Sidebar/NetworkSection.swift`
  - `Sources/MacCommander/Tags/TagMenu.swift`: the custom tags
- Test: `Tests/MacCommanderCoreTests/TagCatalogTests.swift`

**Interfaces:**
- Consumes: `PreferencesStore.preferences.hiddenSidebarSections` (Task 2), `BrowserModel.showTag` (Task 6), `FileTag` (Task 3).
- Produces:
  - `@MainActor @Observable public final class TagCatalog`:
    - `public static let shared`
    - `public private(set) var tags: [FileTag]`
    - `public func start(standard: [FileTag])`. It starts a live `NSMetadataQuery` with predicate `kMDItemUserTags == "*"`, `valueListAttributes = [kMDItemUserTags]` and scope `NSMetadataQueryUserHomeScope`, then reads `valueLists` on each update.
    - `public func noteUsed(_ tag: FileTag)`: tags set in-app appear at once.
    - `public static func merge(standard: [FileTag], inUse: [String], known: [FileTag]) -> [FileTag]`, a pure function. It returns the standard tags in the given order, then the custom names that aren't standard (case-insensitive), sorted with `localizedStandardCompare`. Each custom tag takes its color from `known` when one is there, else `.none`.

- [ ] **Step 1: Write the failing tests.**
  - `mergeOrdersStandardThenCustom`: `merge(standard: [Red, Orange], inUse: ["zeta", "red", "Alpha"], known: [])` gives `[Red, Orange, Alpha, zeta]`.
  - `mergeUsesKnownColors`: `known: [FileTag("Alpha", .blue)]` gives Alpha in blue.
  - `noteUsedAddsCustom`: on a catalog that was never started, `noteUsed` adds the tag and `tags` contains it.
- [ ] **Step 2: Run them.**
  - Command: `scripts/test.sh --filter TagCatalogTests`
  - Expected: FAIL.
- [ ] **Step 3: Implement `TagCatalog`.**
  - `AppDelegate.applicationDidFinishLaunching` calls `start(standard: TagMenu.standardTags())`.
  - `TagMenu` lists `TagCatalog.shared.tags` and calls `noteUsed` after a successful add.
- [ ] **Step 4: Build the sidebar.**
  - **Section order:** Favorites, iCloud Drive, Locations, Network, Tags.
  - **Hiding:** each section is hidden when it is in `hiddenSidebarSections`.
  - **iCloud Drive:**
    - The section has one row, "iCloud Drive" (symbol `icloud`), for `~/Library/Mobile Documents/com~apple~CloudDocs`.
    - It is shown only when that folder exists. Check through `PathQueries.info` in `.task`.
    - Clicking the row navigates there, and the row accepts drops like a Favorites row.
  - **Network:** always shown when not hidden. With no saved shares, it holds one row, "Connect to Server…" (symbol `plus.circle`), which sets `shareSheets.showConnectToServer = true`.
  - **Tags:**
    - Each catalog tag gets a row with a colored circle and its name.
    - A click runs `model.showTag(name)`.
    - The context menu has "Remove Tag from Sidebar". It adds the name to a new `Preferences.hiddenTags: Set<String>`. Add that field in this task, with a lenient decode and a test in `PreferencesTests`.
- [ ] **Step 5: Run the full suite and build.**
  - Commands: `scripts/test.sh && scripts/build-app.sh`
  - Expected: both pass.
- [ ] **Step 6: Commit.** Message: `feat: sidebar Tags and iCloud Drive sections; Network section always shown`.

### Task 8: iCloud status and download on open; opens off the main thread

Carry-over: OpenWithMenu's open and "Open with Archive Utility" still call NSWorkspace on main.

**Files:**
- Modify:
  - `Sources/MacCommander/FileList/FileCellViews.swift` and `FileListController+Outline.swift`: the cloud icon
  - `Sources/MacCommanderCore/Browser/BrowserModel.swift`: `open`
  - `Sources/MacCommanderCore/FileSystem/PathQueries.swift`
  - `Sources/MacCommander/Operations/OpenWithMenu.swift`
  - `Sources/MacCommander/FileList/FileContextMenu.swift`: Open with Archive Utility
- Test: `Tests/MacCommanderCoreTests/BrowserModelTests.swift`

**Interfaces:**
- Consumes: `FileItem.cloudStatus` (Task 3).
- Produces:
  - `PathQueries.startDownloading(_ url: URL) async`: `FileManager.startDownloadingUbiquitousItem` on the blocking queue, with errors ignored.
  - `PathQueries.open(_ urls: [URL], withApplicationAt app: URL?) async`: `NSWorkspace.shared.open(_:withApplicationAt:configuration:)` off main. A nil app means the default app. It returns any error for the caller to show.
  - `BrowserModel.open(_:)`: for a file with `cloudStatus == .notDownloaded`, call the new init hook `downloader: @MainActor (URL) async -> Void = { await PathQueries.startDownloading($0) }` before `opener`.

- [ ] **Step 1: Write the failing test.** `openNotDownloadedTriggersDownload`: build a `FileItem` with `cloudStatus = .notDownloaded`. Make it in a test through an internal initializer; add one if needed. `open(item)` calls the fake downloader, then the fake opener, in that order.
- [ ] **Step 2: Run it.**
  - Command: `scripts/test.sh --filter BrowserModelTests`
  - Expected: FAIL.
- [ ] **Step 3: Implement the model and `PathQueries` parts.**
- [ ] **Step 4: Build the UI.**
  - **The cloud icon:** a trailing `icloud.and.arrow.down` symbol in the name cell for `.notDownloaded`, and `arrow.down.circle` while `.downloading`. It is secondary-colored, with a tooltip of "Not downloaded" or "Downloading".
  - **OpenWithMenu:** its open actions and "Open with Archive Utility" use `PathQueries.open`. An error shows `NSAlert(error:)` on main.
  - Finally, grep `Sources/MacCommander` for `NSWorkspace.shared.open` and confirm there are no main-thread calls left. Revealing in Finder (`activateFileViewerSelecting`) is fine.
- [ ] **Step 5: Run the full suite and build.**
  - Commands: `scripts/test.sh && scripts/build-app.sh`
  - Expected: both pass.
- [ ] **Step 6: Commit.** Message: `feat: iCloud download status and download on open; all opens off main`.

### Task 9: Settings window

Carry-over: the Settings window must include the network-share list.

**Files:**
- Create:
  - `Sources/MacCommander/Settings/SettingsView.swift`
  - `Sources/MacCommander/Settings/GeneralSettings.swift`
  - `Sources/MacCommander/Settings/SidebarSettings.swift`
  - `Sources/MacCommander/Settings/NetworkSettings.swift`
- Modify:
  - `Sources/MacCommander/App/MacCommanderApp.swift`: the `Settings { }` scene
  - `Sources/MacCommander/Shares/ShareActions.swift` and `SignInSheet.swift`: `model` becomes optional

**Interfaces:**
- Consumes: `PreferencesStore` (Tasks 2 and 7), `ViewSettingsStore`, `ShareStore`, `ShareManager`, `ShareActions`, `EditShareSheet`, `ConnectToServerSheet`.
- Produces:
  - `ShareActions.connect` and `handle`, and `SignInSheet.init`, take `model: BrowserModel?`. With nil they connect without navigating.
  - `ConnectToServerSheet` takes `model: BrowserModel?` in the same way.

- [ ] **Step 1: Build the Settings scene** with a `TabView` of three tabs.
  - **General:**
    - Toggles bound to `ViewSettingsStore`: "Show checkbox column" and "Show hidden files".
    - A text field "Default name for new files". Below it, a red line, "Not a valid file name; “untitled.txt” is used.", whenever `Preferences.isValidFileName` is false.
    - "New windows open:" with the current folder's path and a "Choose…" button (`NSOpenPanel`, folders only) plus "Home".
    - A "Full Disk Access…" button, which opens the onboarding sheet from Task 10.
  - **Sidebar:** one toggle per `SidebarSection`, with the titles "Favorites", "iCloud Drive", "Locations", "Network" and "Tags". A second list holds the hidden tags with "Show" buttons.
  - **Network:**
    - A `List` of saved shares with a status dot (the same symbols as `NetworkSection`; reuse its helper), the name and the URL.
    - Buttons that act on the selected share: Connect, Disconnect, Edit… and Remove…. Their enabled rules match the context menu.
    - "Connect to Server…" opens `ConnectToServerSheet(model: nil, …)` in the Settings window, with a `ShareSheets` owned by the view and a `WindowReader`.
- [ ] **Step 2: Build and run by hand.**
  - Run: `scripts/build-app.sh --open`, then press ⌘,.
  - Every control changes the app live, and the changes persist across a relaunch.
- [ ] **Step 3: Run the full suite.**
  - Run: `scripts/test.sh`
  - Expected: all pass.
- [ ] **Step 4: Commit.** Message: `feat: Settings window with general, sidebar and network tabs`.

### Task 10: Launch alert queue and Full Disk Access onboarding

Carry-over: launch alerts can stack.

**Files:**
- Create:
  - `Sources/MacCommander/App/LaunchAlertQueue.swift`
  - `Sources/MacCommander/App/FullDiskAccessHint.swift`
  - `Sources/MacCommanderCore/System/FullDiskAccess.swift`
- Modify: `Sources/MacCommander/App/MacCommanderApp.swift`. Route the share-store error and `RememberSharePrompter` through the queue.
- Test: `Tests/MacCommanderCoreTests/FullDiskAccessTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor final class LaunchAlertQueue`:
    - `static let shared`
    - `func enqueue(_ present: @escaping @MainActor () async -> Void)`
    - Alerts run strictly one after another.
  - `public enum FullDiskAccess`:
    - `public static func isGranted(probe: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Safari")) -> Bool`. It is true when `contentsOfDirectory` on the probe succeeds. A probe that doesn't exist counts as granted, so the app never nags when it can't tell.
    - `public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!`

- [ ] **Step 1: Write the failing tests.**
  - `missingProbeCountsAsGranted`
  - `readableProbeIsGranted`: a temp folder.
  - `unreadableProbeIsNotGranted`: a temp folder with mode 0o000, restored afterwards.
- [ ] **Step 2: Run them.**
  - Command: `scripts/test.sh --filter FullDiskAccessTests`
  - Expected: FAIL.
- [ ] **Step 3: Implement the queue.** Wire the existing alerts through it.
- [ ] **Step 4: Add the onboarding.**
  - At launch, if `!preferences.didShowFullDiskAccessHint`, enqueue a hint. The check runs off main through `PathQueries.run`, and the hint is enqueued only when FDA is not granted.
  - The hint is an `NSAlert` with this copy:
    - Title: "Give MacCommander Full Disk Access?"
    - Body: "MacCommander works without it, but macOS will ask for permission folder by folder, and some locations (like Mail or Safari data) stay hidden. You can grant access in System Settings › Privacy & Security › Full Disk Access."
    - Buttons: "Open System Settings" and "Not Now".
  - Set `didShowFullDiskAccessHint = true` whichever button is chosen.
  - The Settings "Full Disk Access…" button shows the same alert, unqueued.
- [ ] **Step 5: Run the full suite and build.**
  - Commands: `scripts/test.sh && scripts/build-app.sh`
  - Expected: both pass.
- [ ] **Step 6: Commit.** Message: `feat: queue launch alerts; Full Disk Access onboarding`.

### Task 11: App icon

**Files:**
- Create:
  - `scripts/make-icon.swift`: draws the icon with CoreGraphics and writes the iconset PNGs
  - `Resources/AppIcon.iconset/*.png`: the generated files, committed
- Modify: `scripts/build-app.sh`, `Resources/Info.plist`

**Interfaces:** none.

- [ ] **Step 1: Write `scripts/make-icon.swift`.**
  - Run it with `swift scripts/make-icon.swift Resources/AppIcon.iconset`.
  - It writes the 10 standard iconset files: `icon_16x16.png` through `icon_512x512@2x.png`.
  - The design is the macOS rounded-square shape (about 22.4% corner radius, inset 10% like Big Sur icons).
    - A dark-blue vertical gradient, `#1E3A8A` to `#0F172A`.
    - Two light panes side by side with a thin gap, a nod to Total Commander.
    - A white folder-tab glyph on the left pane.
  - A placeholder is fine (spec §8). It must stay legible at 16 px.
- [ ] **Step 2: Generate the PNGs and wire the build.**
  - Run the script and commit the PNGs.
  - In `build-app.sh`, before signing: `iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"`.
  - In `Info.plist`: `<key>CFBundleIconFile</key><string>AppIcon</string>`.
- [ ] **Step 3: Build and check.**
  - Run: `scripts/build-app.sh && test -f build/MacCommander.app/Contents/Resources/AppIcon.icns && echo ok`
  - Expected: `ok`. The Dock shows the icon after `--open`.
- [ ] **Step 4: Commit.** Message: `feat: app icon`.

### Task 12: Small carry-over polish

**Files:**
- Modify:
  - `Sources/MacCommander/Preview/MarkdownWebView.swift`
  - `Sources/MacCommanderCore/Shares/KeychainCredentialStore.swift`

- [ ] **Step 1: Keep the Markdown scroll position.** When the same file re-renders after a live update, keep the scroll position.
  - Before the reload, read it with `evaluateJavaScript("window.scrollY")`. App-injected evaluation works with content JavaScript off.
  - After the load finishes, restore it with `window.scrollTo(0, y)`.
  - A different file still starts at the top.
- [ ] **Step 2: Replace the deprecated `kSecUseAuthenticationUI`.** Use `kSecUseAuthenticationContext` with an `LAContext` whose `interactionNotAllowed = true`, keeping the "never show UI for background reads" behavior. Import `LocalAuthentication`.
- [ ] **Step 3: Check the build and tests.**
  - Run: `swift build 2>&1 | grep -c kSecUseAuthenticationUI` (expected: `0`), then `scripts/test.sh` (expected: all pass).
  - If `MC_KEYCHAIN_TESTS=1` is available, run the Keychain suite as well.
- [ ] **Step 4: Commit.** Message: `fix: keep Markdown scroll on live update; drop deprecated Keychain UI flag`.

---

## Manual checklist (after the final review)

- **M1 (tags):** Tag a file Red in MacCommander, and Finder shows it red. Tag one in Finder, and the dot shows in MacCommander. A custom tag via New Tag… appears in the sidebar. Clicking a sidebar tag lists every file with it, with a Location column. ⌘[ closes the tag view.
- **M2 (search):**
  - Typing in ~/Documents finds nested files and shows Location.
  - Clearing the field restores the folder.
  - A search for `*` or `"` finds only names containing that character.
- **M3 (network search):** Search on the NAS share by enumeration: the app stays responsive, and typing a new query replaces the old one. Search with the NAS switched off: no freeze.
- **M4 (iCloud):** The iCloud Drive sidebar row shows, and evicted files show the cloud icon. Double-clicking one downloads and opens it.
- **M5 (Settings):** Each toggle takes effect live. "Default name for new files" set to `notes.md` gives New Empty File `notes.md`. New windows open in the chosen folder. The Network tab's Connect, Disconnect, Edit and Remove work.
- **M6 (launch):** With a fresh preferences domain (`defaults delete dev.noix.MacCommander`), the FDA hint shows once and never stacks with "Remember this share?".
- **M7 (iCloud signed out):** On a Mac without iCloud Drive, the row is hidden.
- **M8 (icon):** The icon shows in the Dock, Finder and ⌘-Tab.
