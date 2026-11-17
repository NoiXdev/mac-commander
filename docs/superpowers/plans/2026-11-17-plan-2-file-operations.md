# MacCommander Plan 2: File Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MacCommander can copy, cut/move, paste, duplicate, move to Trash, compress, and drag and drop files. Long operations show progress and can be cancelled. Name conflicts ask Replace / Keep Both / Skip / Stop. ⌘Z undoes rename, move, copy, new folder/file, duplicate and trash. Also included: Open With, Get Info, Copy Path and Reveal in Finder, plus a fix for the Plan 1 watcher regression.

**Architecture:** All file-system work lives in `MacCommanderCore` under `Operations/`:
- `FileTransfer`: the copy/move engine, using `copyfile(3)` with progress and cancellation.
- `Trasher`: moves items to the Trash.
- `FileUndoStack`: undo records.
- `FileClipboard`: copy/cut through the pasteboard.
- `DropPolicy`: the move/copy decision for drops.
- `Compressor` (`ditto`) and `FolderSizeCalculator`.
- `FileOperationCenter`: one app-wide `@MainActor @Observable` object that runs operations, publishes their progress, records undo and tells windows which folders changed.

The UI goes through the center:
- Keyboard and menu commands travel the responder chain to the focused `FileOutlineView`.
- The conflict dialog is an `NSAlert` sheet.
- Progress appears in a strip at the bottom of the window.

**Tech Stack:** Swift 6, SwiftUI, AppKit, `copyfile(3)`, `/usr/bin/ditto`, Swift Testing, SwiftPM, macOS 15+.

**Spec:** `docs/superpowers/specs/2026-11-17-maccommander-design.md` (§2.1 File operations, Drag and drop, Keyboard, Get Info, Context menu; §4 Anti-goals). Plan 1 (`docs/superpowers/plans/2026-11-17-plan-1-foundation.md`) built everything this plan extends.

### Roadmap position
This is plan 2 of 6. Next come Plan 3 (archives), Plan 4 (preview + Markdown), Plan 5 (network shares) and Plan 6 (tags, search, iCloud, Settings, icon). The Tags ▸ context-menu entry and the tags row in Get Info are added in Plan 6.

## Global Constraints
- macOS 15 minimum, Swift 6 language mode, no App Sandbox. Build and test with **Command Line Tools only**, running tests with `scripts/test.sh`. Use Swift Testing (`import Testing`), not XCTest. The SwiftUI macros `@State`, `@Entry` and `@FocusedValue`-key macros don't compile under CLT. Use `State<T>` stored properties and hand-written `FocusedValueKey`s, as Plan 1 does.
- Spec §4, verbatim: "Data loss: deletes must go to the Trash (no permanent delete in v1). Moves across volumes copy first and delete the source only after the copy succeeds. Conflicts never overwrite silently."
  - "Replace" therefore moves the existing item to the Trash. It never deletes it.
  - Permanently removing anything is allowed only in two cases: a partial destination this operation itself created, and the source of a cross-volume move after its copy succeeded.
- No file-system work on the main thread. This covers enumeration, copying, trashing, size scans and `ditto`. Use `@concurrent` static functions, as `BrowserModel` does.
- Spec §2.1 sets these keyboard shortcuts:
  - ⌘C copy, ⌘X cut, ⌘V paste, ⌥⌘V move here
  - ⌘D duplicate, ⌘⌫ Move to Trash, ⌘Z undo
  - ⌘I Get Info, ⌥⌘C Copy Path (Finder's shortcut)
- Drag and drop moves on the same volume and copies across volumes. ⌥ forces copy and ⌘ forces move.
- Name formats (match Finder):
  - Duplicate, or a copy pasted into its own folder: `name copy.ext`, then `name copy 2.ext`, `name copy 3.ext`, …
  - Keep Both: `name 2.ext`, `name 3.ext`, …
  - Compress: `name.zip` for one item (`a.txt` → `a.txt.zip`) and `Archive.zip` (then `Archive 2.zip`) for several.
- Keep UI strings English and localizable with `String(localized:)`. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on `main`, without worktrees.
- Don't write `.DS_Store` or other Finder metadata.

## Review Focus
1. **Copying or moving a folder into itself or one of its subfolders**, by paste or drop, is refused with a message, and nothing on disk changes. Pinned in Task 4 (`FileTransfer`) and Task 7 (`DropPolicy`).
2. **A cross-volume move that fails or is cancelled midway** (unreadable file, disk full, Cancel) leaves the source completely intact and removes the partial destination. Pinned in Task 4.
3. **Pasting a copy into the folder it came from, or Keep Both on `report 2.txt`**, creates `report copy.txt` or `report 3.txt`. No dialog appears and nothing is overwritten. Pinned in Task 3 and Task 4.
4. **Undo after the world changed** (the moved item was deleted since, or its original location is now occupied): an error message appears, nothing is overwritten, and the record is dropped. Pinned in Task 5.
5. **Symlinks and packages inside a copied folder** are copied as links and as whole bundles. The copy never follows a link out of the tree. Pinned in Task 4.

---

## File Structure

```
Sources/MacCommanderCore/
  FileSystem/NameGenerator.swift          + copyName / keepBothName (Task 3)
  FileSystem/FolderSizeCalculator.swift   recursive size for Get Info (Task 11)
  Operations/FileTransfer.swift           copy/move engine, conflicts, progress, cancel (Task 4)
  Operations/Trasher.swift                move to Trash, put back (Task 5)
  Operations/FileUndoStack.swift          undo records and their execution (Task 5)
  Operations/Compressor.swift             ditto-based zip (Task 6)
  Operations/FileOperationCenter.swift    app-wide runner, progress, undo, change notices (Task 6)
  Operations/FileClipboard.swift          copy / cut / paste intent via NSPasteboard (Task 7)
  Operations/DropPolicy.swift             move vs copy vs refuse for drops (Task 7)
  Browser/BrowserModel.swift              watcher identity (Task 1); undo + select-after-op (Task 8)
Sources/MacCommander/
  FileList/FileListController*.swift      split into focused extensions (Task 2)
  FileList/FileOutlineView.swift          responder-chain actions (Task 9), drag/drop (Task 12)
  FileList/FileContextMenu.swift          full item / empty-space menus (Task 10)
  Operations/ConflictPrompter.swift       NSAlert sheet → ConflictDecision (Task 9)
  Operations/OperationsStrip.swift        bottom progress strip (Task 9)
  Operations/OpenWithMenu.swift           Open With ▸ submenu (Task 10)
  Info/InfoWindow.swift                   Get Info window (Task 11)
  App/BrowserCommands.swift, App/MacCommanderApp.swift, Browser/BrowserWindow.swift, Sidebar/SidebarView.swift
Tests/MacCommanderCoreTests/
  NameGeneratorTests, FileTransferTests, TrasherTests, FileUndoStackTests, CompressorTests,
  FileOperationCenterTests, FileClipboardTests, DropPolicyTests, FolderSizeCalculatorTests, BrowserModelTests
```

---

### Task 1: Watch the recreated folder (Plan 1 residual)

The bug: when the open folder is deleted and recreated at the same path, `BrowserModel.startWatching` returns early because `watchedURL == url`. The watcher is still attached to the dead vnode, so the list stops updating live.

**Files:**
- Modify: `Sources/MacCommanderCore/Browser/BrowserModel.swift` (`startWatching`, new `watchedIdentity`)
- Test: `Tests/MacCommanderCoreTests/BrowserModelTests.swift`

**Interfaces:**
- Produces: nothing public. A private `struct FolderIdentity: Equatable { let device: dev_t; let inode: ino_t }`, read with `stat(2)` on the path.

- [ ] **Step 1: Write the failing test** `@Test func recreatedFolderIsWatchedAgain()`:
  1. Navigate to `tmp/work`.
  2. `removeItem(work)`, then `createDirectory(work)`.
  3. `await model.reload()`.
  4. Wait for stale events to drain: `try await Task.sleep(for: .milliseconds(1500))`, which is longer than the watcher's 1 s maximum latency.
  5. Create `work/new.txt`.
  6. `#expect(await waitUntil { model.items.map(\.name) == ["new.txt"] })`.
- [ ] **Step 2: Run** `scripts/test.sh --filter recreatedFolderIsWatchedAgain`. Expected: FAIL (timeout).
- [ ] **Step 3: Implement.** `startWatching` keeps the existing watcher only when `watchedURL == url` **and** the current `FolderIdentity` of `url` equals `watchedIdentity`. Otherwise it cancels the watcher and creates a new one. If `stat` fails, it always recreates.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all tests pass.
- [ ] **Step 5: Commit** `fix(core): rewatch a folder that was deleted and recreated`

---

### Task 2: Split `FileListController` and define the selection contract

`FileListController.swift` is 846 lines. Every later UI task edits it, so split it first. The split is a pure refactor with no behavior change.

**Files:**
- Modify: `Sources/MacCommander/FileList/FileListController.swift`. It keeps setup, status views and observation.
- Create:
  - `FileListController+Tree.swift`: `FileNode`, `applyItems`, `apply(_:in:)`, expansion, child loading.
  - `FileListController+Selection.swift`: model ↔ table sync, checkbox states, select all.
  - `FileListController+Columns.swift`: columns, layout persistence, sort indicator, header menu.
  - `FileListController+Outline.swift`: `NSOutlineViewDataSource` and `NSOutlineViewDelegate`.
  - Icons go in the file that reads best.
- All files are in `Sources/MacCommander/FileList/`.

**Interfaces:**
- Produces, in `FileListController+Selection.swift`, the selection contract that every later file command uses:
  - `var selectedItems: [FileItem]`: the selected rows' items in row order, including rows of inline-expanded subfolders.
  - `func actionItems(forClickedRow row: Int) -> [FileItem]`:
    - the whole selection if `row` is selected,
    - only that row's item if it isn't,
    - `[]` for `row < 0`.
  - `FileContextMenu.forItems` receives `actionItems(forClickedRow:)`, and keyboard and menu commands use `selectedItems`. Nothing outside the controller reads `outlineView.selectedRowIndexes` to decide what an operation acts on.

- [ ] **Step 1: Move code without changing it.** Properties that more than one file needs become `internal` (they are still private to the module). No file is over ~350 lines.
- [ ] **Step 2: Add `selectedItems` and `actionItems(forClickedRow:)`**, and route the existing context-menu builder through `actionItems`.
- [ ] **Step 3: Verify.** `swift build` succeeds and `scripts/test.sh` passes. Then run `scripts/build-app.sh --open` and confirm:
  - Navigation, sorting and inline expansion still work.
  - Checkboxes, header tri-state, context menus and inline rename still work.
  - Quick Look still works.
- [ ] **Step 4: Commit** `refactor(ui): split FileListController; add selection contract`

---

### Task 3: Copy and Keep-Both names

**Files:**
- Modify: `Sources/MacCommanderCore/FileSystem/NameGenerator.swift`
- Test: `Tests/MacCommanderCoreTests/NameGeneratorTests.swift`

**Interfaces:**
- Consumes: `NameGenerator.uniqueName(base:pathExtension:in:fileManager:)`. It treats dangling symlinks as taken, because it uses lstat.
- Produces:
  - `NameGenerator.copyName(for name: String, isDirectory: Bool, in directory: URL) -> String`
  - `NameGenerator.keepBothName(for name: String, isDirectory: Bool, in directory: URL) -> String`
  - Both split the extension only for non-directories with a non-empty `pathExtension`. A name starting with a dot, such as `.zshrc`, has no extension.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func copyNames() throws {
    let tmp = try TemporaryDirectory()
    try tmp.file("report.txt")
    #expect(NameGenerator.copyName(for: "report.txt", isDirectory: false, in: tmp.url) == "report copy.txt")
    try tmp.file("report copy.txt")
    #expect(NameGenerator.copyName(for: "report.txt", isDirectory: false, in: tmp.url) == "report copy 2.txt")
    // Duplicating a copy continues its number instead of stacking "copy copy".
    #expect(NameGenerator.copyName(for: "report copy.txt", isDirectory: false, in: tmp.url) == "report copy 2.txt")
    try tmp.folder("my.folder")
    #expect(NameGenerator.copyName(for: "my.folder", isDirectory: true, in: tmp.url) == "my.folder copy")
    #expect(NameGenerator.copyName(for: ".zshrc", isDirectory: false, in: tmp.url) == ".zshrc copy")
}

@Test func keepBothNames() throws {
    let tmp = try TemporaryDirectory()
    try tmp.file("report.txt")
    #expect(NameGenerator.keepBothName(for: "report.txt", isDirectory: false, in: tmp.url) == "report 2.txt")
    try tmp.file("report 2.txt")
    #expect(NameGenerator.keepBothName(for: "report 2.txt", isDirectory: false, in: tmp.url) == "report 3.txt")
    #expect(NameGenerator.keepBothName(for: "Ärger.md", isDirectory: false, in: tmp.url) == "Ärger.md")
}
```

The last assertion holds because an unused name is returned unchanged, which `FileTransfer` relies on. The trailing-number rule: a stem ending in `" <n>"` (or `" copy <n>"`) continues from `n + 1`.

- [ ] **Step 2: Run** `scripts/test.sh --filter NameGenerator`. Expected: FAIL (the functions don't exist yet).
- [ ] **Step 3: Implement** both functions on top of `uniqueName`.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all tests pass.
- [ ] **Step 5: Commit** `feat(core): Finder-style copy and keep-both names`

---

### Task 4: `FileTransfer`, the copy and move engine

**Files:**
- Create: `Sources/MacCommanderCore/Operations/FileTransfer.swift`
- Test: `Tests/MacCommanderCoreTests/FileTransferTests.swift`

**Interfaces:**
- Consumes: the `NameGenerator` functions from Task 3.
- Produces (all `public`, `Sendable`):

```swift
public enum TransferMode: Sendable { case copy, move }
public enum ConflictChoice: Sendable { case replace, keepBoth, skip, stop }
public struct ConflictDecision: Sendable { public var choice: ConflictChoice; public var applyToAll: Bool }
public struct TransferConflict: Sendable { public let source: URL; public let existing: URL; public let mode: TransferMode; public let moreItemsFollow: Bool }
public typealias ConflictResolver = @Sendable (TransferConflict) async -> ConflictDecision
public struct TransferProgress: Sendable, Equatable { public var totalBytes: Int64; public var completedBytes: Int64; public var totalItems: Int; public var completedItems: Int; public var currentName: String? }
public struct TransferredItem: Sendable, Equatable { public let source: URL; public let destination: URL }
public struct TrashedItem: Sendable, Equatable { public let original: URL; public let trashed: URL }
public enum TransferError: Error, Equatable { case intoItself(name: String); case failed(name: String, message: String) }
public enum TransferOutcome: Sendable, Equatable { case finished, stopped, cancelled, failed(TransferError) }
public struct TransferResult: Sendable, Equatable { public var completed: [TransferredItem]; public var replaced: [TrashedItem]; public var skipped: [URL]; public var outcome: TransferOutcome }

public enum FileTransfer {
    @concurrent public static func run(
        _ sources: [URL], into destination: URL, mode: TransferMode,
        resolver: ConflictResolver,
        trash: @Sendable (URL) throws -> URL = Trasher.systemTrash,      // Task 5 defines Trasher; until then a local default calling FileManager.trashItem
        sameVolume: @Sendable (URL, URL) -> Bool = FileTransfer.isSameVolume,
        progress: @Sendable (TransferProgress) -> Void = { _ in }
    ) async -> TransferResult
    public static func isSameVolume(_ a: URL, _ b: URL) -> Bool   // .volumeIdentifierKey of a and of b's folder
}
```

**Rules:**
- **Order.** Sources are processed in the given order and only at the top level. Conflicts are checked per source item, not per nested file.
- **Into itself.** If any source is `destination` itself or one of its ancestors (compare resolved paths), the operation returns `.failed(.intoItself)` before touching anything.
- **Same location.** A source whose parent is `destination`:
  - with `.copy`, is copied to `copyName` without asking;
  - with `.move`, is a no-op and counts as completed with `destination == source`.
- **Conflicts.** When the destination name exists, the engine calls `resolver` unless an earlier `applyToAll` decision applies.
  - `replace`: the existing item goes to the Trash through `trash(_:)` and is recorded in `replaced`. Then the transfer runs.
  - `keepBoth`: the item is written under `keepBothName`.
  - `skip`: the item is recorded in `skipped`.
  - `stop`: the engine returns `.stopped` with everything done so far.
  - `moreItemsFollow` is true when items remain after this one.
- **Copying.** Use `copyfile(src, dst, state, COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_CLONE)`. A clone on APFS completes instantly and gives no per-byte progress, which is fine.
  - Progress: set `COPYFILE_STATE_STATUS_CB` and `COPYFILE_STATE_STATUS_CTX` to a `@convention(c)` callback with a retained context box. The box holds an `Atomic<Bool>` cancel flag (`Synchronization`) and the progress closure. On `COPYFILE_COPY_DATA` / `COPYFILE_PROGRESS`, read `COPYFILE_STATE_COPIED`.
  - Cancellation: the callback returns `COPYFILE_QUIT` once the flag is set. `withTaskCancellationHandler` sets the flag.
- **Partial output.** When copying an item fails or is cancelled, its partial destination is removed with `removeItem`. This is the only permanent delete besides the next rule.
- **Moving.**
  - Same volume: `FileManager.moveItem`, a rename.
  - Different volume: copy as above, then `removeItem(source)` only after the copy returned success. If the copy fails or is cancelled, the source is untouched.
- **Progress.** Before any work, a pre-scan (`FileManager.enumerator`, regular-file sizes, no link following) sets `totalBytes` and `totalItems = sources.count`. `progress` is called whenever a top-level item finishes and from the copy callback. The caller throttles.
- **Errors.** The first `copyfile` or `moveItem` error ends the run with `.failed(.failed(name:message:))`, where `message` is the `strerror` / `localizedDescription` text. Earlier completed items stay in `completed`, so undo can cover them.

- [ ] **Step 1: Write the failing tests** in `FileTransferTests.swift`. Use `TemporaryDirectory` with `src/` and `dst/` folders. The `resolver` is a test closure that records conflicts and returns scripted decisions. `trash` moves into a `tmp/Trash/` folder, so tests never touch the user's real Trash.
  - `copyIntoOtherFolder`: copying `src/a.txt` ("A") and `src/dir/b.txt` into `dst` leaves both sources in place. `dst/a.txt == "A"`, `dst/dir/b.txt` exists, `completed.count == 2` and `outcome == .finished`.
  - `copyIntoSameFolderMakesCopyName`: copying `src/a.txt` into `src` gives `src/a copy.txt`, and the resolver is never called.
  - `moveSameVolumeRenames`: `src/a.txt` is gone and `dst/a.txt` exists.
  - `moveAcrossVolumesCopiesThenDeletes`: with `sameVolume: { _, _ in false }`, the source is gone and the destination exists.
  - `crossVolumeMoveFailureKeepsSource`: `src/dir` contains `ok.txt` and `locked.txt` with mode `000`. With `sameVolume` false, `outcome` is `.failed`, `src/dir/ok.txt` and `src/dir/locked.txt` still exist, and `dst/dir` does not exist. Restore permissions in `defer`.
  - `cancelKeepsSourceAndRemovesPartial`: write a 200 MB file with `ftruncate` plus one byte at the end, or real data if `COPYFILE_CLONE` would make the copy instant. Disabling cloning is test-only: add the internal parameter `allowClone: Bool = true` for this. Start the run in a `Task`, cancel it after the first progress callback reports `completedBytes > 0`, and expect `.cancelled`, the source intact, and no `dst/big.bin`.
  - `moveIntoItselfIsRefused`: moving `src/dir` into `src/dir/sub` gives `.failed(.intoItself(name: "dir"))`, and the tree is unchanged.
  - `conflictReplaceTrashesExisting`: `dst/a.txt` ("old") and Replace give `dst/a.txt == "new"` and `replaced.count == 1`, and the trashed file contains "old".
  - `conflictKeepBothSkipStopAndApplyToAll`:
    - three conflicting files with `keepBoth + applyToAll` call the resolver once and produce `a 2.txt`, `b 2.txt` and `c 2.txt`;
    - a second run with `skip` leaves `skipped == [src/a.txt]`;
    - `stop` on the first conflict gives `.stopped` and an empty `completed`.
  - `symlinksAndPackagesCopiedAsIs`: `src/dir/link → /etc` and `src/dir/App.app/Contents/x`. After copying, `dst/dir/link` is a symlink whose `destinationOfSymbolicLink == "/etc"`, and `dst/dir/App.app/Contents/x` exists.
  - `progressReportsTotals`: the last reported progress has `completedItems == totalItems == 2` and `completedBytes == totalBytes`.
- [ ] **Step 2: Run** `scripts/test.sh --filter FileTransfer`. Expected: FAIL (`FileTransfer` doesn't exist).
- [ ] **Step 3: Implement** `FileTransfer.swift` according to the rules above.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all tests pass. Run `--filter FileTransfer` 3 times, and it must not be flaky.
- [ ] **Step 5: Commit** `feat(core): copy/move engine with conflicts, progress and cancel`

---

### Task 5: `Trasher` and `FileUndoStack`

**Files:**
- Create: `Sources/MacCommanderCore/Operations/Trasher.swift`, `Sources/MacCommanderCore/Operations/FileUndoStack.swift`
- Modify: `FileTransfer.swift`, so its `trash` default is `Trasher.systemTrash`.
- Test: `Tests/MacCommanderCoreTests/TrasherTests.swift`, `Tests/MacCommanderCoreTests/FileUndoStackTests.swift`

**Interfaces:**
- Consumes: `TransferredItem`, `TrashedItem` and `TransferMode` from Task 4.
- Produces:

```swift
public struct TrashResult: Sendable, Equatable { public var trashed: [TrashedItem]; public var failures: [TrashFailure] }
public struct TrashFailure: Sendable, Equatable { public let url: URL; public let message: String }
public enum Trasher {
    public static let systemTrash: @Sendable (URL) throws -> URL   // FileManager.trashItem(at:resultingItemURL:)
    @concurrent public static func trash(_ urls: [URL], using trash: @Sendable (URL) throws -> URL = systemTrash) async -> TrashResult
}

public enum FileUndoAction: Sendable, Equatable {
    case rename(from: URL, to: URL)
    case created([URL])                                            // new folder/file; undo trashes
    case transferred(TransferMode, [TransferredItem], replaced: [TrashedItem])   // copy, duplicate, move
    case trashed([TrashedItem])                                     // undo = put back
}
public struct FileUndoRecord: Sendable, Equatable { public let action: FileUndoAction; public let title: String }
public enum UndoError: Error, Equatable { case nothingToUndo; case itemChanged(name: String); case failed(name: String, message: String) }

@MainActor @Observable public final class FileUndoStack {
    public init(trash: @escaping @Sendable (URL) throws -> URL = Trasher.systemTrash, limit: Int = 50)
    public private(set) var records: [FileUndoRecord]
    public var undoTitle: String? { records.last?.title }          // e.g. "Move of 3 Items"
    public func push(_ record: FileUndoRecord)
    /// Pops the last record and reverses it off the main actor.
    public func undo() async throws(UndoError) -> [URL]             // URLs restored to view, for selection
}
```

**Undo semantics:**
- **`rename`**: rename `to` back to `from`.
- **`created`**: trash the items.
- **`transferred(.copy, …)`**: trash every `destination` whose `destination != source`.
- **`transferred(.move, …)`**: move every `destination` back to its `source`. A cross-volume move is undone the same way: it copies back, then deletes the moved copy, with the same rules as `FileTransfer`.
- **Replaced items**: after either kind of transfer, every `replaced` item is put back from the Trash to `original`.
- **`trashed`**: move every `trashed` back to `original`.
- **Pre-check.** Before changing anything, check that every item to move exists and every target location is free. Otherwise throw `.itemChanged(name:)` (the first offending item's display name) and **drop the record**. Never overwrite anything.

**Titles** (built by the caller and stored in the record; tested in Task 6):
- `Rename`, `New Folder`, `New File`, `Duplicate`, `Move to Trash`
- `Copy of “a.txt”` / `Copy of 3 Items`
- `Move of “a.txt”` / `Move of 3 Items`

- [ ] **Step 1: Write the failing tests.** In all tests, the `trash` closure moves into `tmp/Trash/` and returns the new URL.
  - `trashMovesItemsAndReportsFailures`: trashing `[a.txt, missing.txt]` gives one `trashed` entry with an existing `trashed` URL and one failure for `missing.txt`.
  - `undoRename`: `a.txt` renamed by hand to `b.txt` plus a pushed `.rename` becomes `a.txt` again after `undo()`, and `records` is empty.
  - `undoMoveAndCopy`:
    - an undone `.move` record of `src/a → dst/a` brings `src/a` back and removes `dst/a`;
    - an undone `.copy` record puts the copy in the test Trash and keeps the original.
  - `undoTrashPutsBack`: trashing through `Trasher`, pushing `.trashed` and undoing gives back the original path with its contents.
  - `undoReplaceRestoresReplacedItem`: an undone `.transferred(.copy, [src/a → dst/a], replaced: [dst/a → Trash/a])` record trashes the new `dst/a` and puts back the old `dst/a` with its old content.
  - `undoRefusesWhenOriginalOccupied`: after a moved record, a new file created at the source path makes `undo()` throw `.itemChanged(name: "a.txt")`. Both files are unchanged and `records` is empty.
  - `undoRefusesWhenItemGone`: when the destination was deleted, `undo()` throws `.itemChanged`.
  - `undoStackLimit`: with `limit: 2` and 3 pushes, `records.count == 2` and the oldest record is dropped.
  - `undoEmptyThrows`: `undo()` throws `.nothingToUndo`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "Trasher|FileUndoStack"`. Expected: FAIL.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all tests pass.
- [ ] **Step 5: Commit** `feat(core): trash with put-back and a file undo stack`

---

### Task 6: `Compressor` and `FileOperationCenter`

**Files:**
- Create: `Sources/MacCommanderCore/Operations/Compressor.swift`, `Sources/MacCommanderCore/Operations/FileOperationCenter.swift`
- Test: `Tests/MacCommanderCoreTests/CompressorTests.swift`, `Tests/MacCommanderCoreTests/FileOperationCenterTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces:

```swift
public enum Compressor {
    /// All `items` share one parent folder. Never overwrites: the archive name is chosen with
    /// `NameGenerator.uniqueName` and written via a temporary name in that folder, then moved
    /// into place with a non-replacing move (retry with the next name on EEXIST).
    @concurrent public static func compress(_ items: [URL]) async throws -> URL
}

public struct FileOperationStatus: Identifiable, Sendable, Equatable {
    public let id: UUID; public let title: String; public var progress: TransferProgress?   // nil = indeterminate
}

@MainActor @Observable public final class FileOperationCenter {
    public static let foldersDidChange: Notification.Name   // userInfo["folders"]: [URL]
    public init(undo: FileUndoStack = FileUndoStack(), trash: @escaping @Sendable (URL) throws -> URL = Trasher.systemTrash,
                sameVolume: @escaping @Sendable (URL, URL) -> Bool = FileTransfer.isSameVolume)
    public let undo: FileUndoStack
    public private(set) var operations: [FileOperationStatus]
    public func transfer(_ sources: [URL], into destination: URL, mode: TransferMode, resolver: @escaping ConflictResolver) async -> TransferResult
    public func duplicate(_ items: [URL]) async -> TransferResult          // copy of each into its own parent
    public func trash(_ items: [URL]) async -> TrashResult
    public func compress(_ items: [URL]) async throws -> URL
    public func cancel(_ id: UUID)
    public func recordRename(from: URL, to: URL)                            // called by BrowserModel (Task 8)
    public func recordCreated(_ url: URL, isFolder: Bool)
    public func performUndo() async throws(UndoError) -> [URL]             // wraps undo.undo(), posts foldersDidChange
}
```

**Behavior:**
- **Status.** Each operation appends a `FileOperationStatus` while it runs and removes it when it ends.
  - Titles: `Copying “a.txt” to “Documents”`, `Copying 3 items to “Documents”`, `Moving …`, `Duplicating …`, `Moving 3 items to the Trash`, `Compressing …`.
  - `progress` updates are throttled to at most one every 100 ms (the last update always lands).
- **Undo.** Any completed work is pushed as one undo record, including the completed part of a stopped, cancelled or failed transfer. Duplicate pushes `.transferred(.copy, …)` titled `Duplicate`. Compress pushes `.created([zip])` titled `Compress`. Trash pushes `.trashed` with only the items that succeeded.
- **Change notices.** After every operation, including undo, the center posts `foldersDidChange` with the set of affected parent folders: destination, source parents and trashed items' parents.
- **Cancel.** `cancel(id)` cancels that operation's `Task`.
- **Compress names.** One item gives `<name>.zip`, made with `ditto -c -k --sequesterRsrc --keepParent <item> <zip>`. Several items give `Archive.zip`: clone the items into a temporary folder with `copyfile(… COPYFILE_CLONE …)`, then run `ditto -c -k --sequesterRsrc <tmpdir> <zip>`, so the items are at the archive root. `ditto` runs as `Process` from `/usr/bin/ditto`. A non-zero exit throws `CocoaError(.fileWriteUnknown)` with ditto's stderr as the description.

- [ ] **Step 1: Write the failing tests**
  - `compressSingleAndMultiple`:
    - `a.txt` gives `a.txt.zip`;
    - `[a.txt, b.txt]` gives `Archive.zip`, then `Archive 2.zip` on a second call;
    - `/usr/bin/unzip -l` on `Archive.zip` lists `a.txt` and `b.txt` at the root, with no folder prefix.
  - `transferPushesUndoAndPostsFolders`: moving `src/a.txt` into `dst` makes `center.undo.undoTitle == "Move of “a.txt”"`. A `foldersDidChange` notification containing `dst` and `src` is received (observe it in the test), and `operations` is empty afterwards.
  - `cancelledTransferStillUndoable`: with a resolver that suspends on the second conflict, `cancel(id)` while it waits ends the transfer as `.cancelled`. The first item is completed and appears in an undo record.
  - `duplicateTitlesAndNames`: duplicating `[a.txt]` creates `a copy.txt` with `undoTitle == "Duplicate"`. A second duplicate creates `a copy 2.txt`.
  - `trashRecordsOnlySuccesses`: trashing `[a.txt, missing]` gives a record with exactly one item.
  - `progressIsThrottled`: copying 50 small files (cloning disabled through an internal `allowClone` passthrough) leaves `operations[0].progress` changed at most `elapsed/0.1 + 2` times. Count the changes with `withObservationTracking` re-arming.
- [ ] **Step 2: Run** `scripts/test.sh --filter "Compressor|FileOperationCenter"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all tests pass.
- [ ] **Step 5: Commit** `feat(core): operation center with progress, undo and compress`

---

### Task 7: `FileClipboard` and `DropPolicy`

**Files:**
- Create: `Sources/MacCommanderCore/Operations/FileClipboard.swift`, `Sources/MacCommanderCore/Operations/DropPolicy.swift`
- Test: `Tests/MacCommanderCoreTests/FileClipboardTests.swift`, `Tests/MacCommanderCoreTests/DropPolicyTests.swift`

**Interfaces:**

```swift
@MainActor public final class FileClipboard {
    public init(pasteboard: NSPasteboard = .general)
    public func copy(_ urls: [URL])            // writes NSURLs; clears the cut marker
    public func cut(_ urls: [URL])             // writes NSURLs; remembers pasteboard.changeCount as cut marker
    public var fileURLs: [URL] { get }         // file URLs on the pasteboard, also from Finder
    /// `.move` if `forceMove` or the pasteboard still holds this app's cut; otherwise `.copy`.
    public func pasteMode(forceMove: Bool) -> TransferMode
    public func didPaste(mode: TransferMode)   // after a move-paste, clears the cut marker (Finder: cut is one-shot)
}

public struct DropModifiers: OptionSet, Sendable { public static let option, command }
public enum DropPolicy {
    /// nil = refuse: destination is a source or inside one, or a move whose sources all already live in destination.
    public static func operation(for sources: [URL], into destination: URL, modifiers: DropModifiers,
                                 sameVolume: (URL, URL) -> Bool = FileTransfer.isSameVolume) -> TransferMode?
}
```

**Rules:**
- The ⌥ modifier gives `.copy` and ⌘ gives `.move`. Otherwise the result is `.move` when every source is on the same volume as the destination, and `.copy` otherwise.
- Dropping onto the source's own parent with ⌥ is allowed and makes a copy.

- [ ] **Step 1: Write the failing tests.** Use `NSPasteboard(name: .init("test-\(UUID())"))` and `releaseGlobally()` in `defer`.
  - `copyThenPasteIsCopy`: after `copy`, `pasteMode(forceMove: false) == .copy`, `pasteMode(forceMove: true) == .move`, and `fileURLs` equals the input.
  - `cutThenPasteIsMoveOnce`: after `cut`, the mode is `.move`. After `didPaste(mode: .move)`, it is `.copy`.
  - `externalChangeCancelsCut`: after `cut` and then another `clearContents()` / `writeObjects` on the same pasteboard, the mode is `.copy`.
  - `dropPolicy`. Paths are in a `TemporaryDirectory`, and `sameVolume` is injected:
    - same volume with no modifiers gives `.move`; different volume gives `.copy`;
    - ⌥ on the same volume gives `.copy`, and ⌘ on a different volume gives `.move`;
    - `dir` into `dir`, or into `dir/sub`, gives nil;
    - `src/a` into `src` with no modifiers gives nil, and with ⌥ gives `.copy`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "FileClipboard|DropPolicy"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: all tests pass.
- [ ] **Step 5: Commit** `feat(core): clipboard cut/copy intent and drop policy`

---

### Task 8: `BrowserModel` integration

**Files:**
- Modify: `Sources/MacCommanderCore/Browser/BrowserModel.swift`, `Sources/MacCommander/App/MacCommanderApp.swift` (one shared `FileOperationCenter` and `FileClipboard`, passed to every window's model and through the environment / focused value like `ViewSettingsStore`)
- Test: `Tests/MacCommanderCoreTests/BrowserModelTests.swift`

**Interfaces:**
- Consumes: `FileOperationCenter` (Task 6).
- Produces:
  - `BrowserModel.init(start:settings:loader:opener:operations: FileOperationCenter = FileOperationCenter())`. The new parameter is last and has a default, so existing tests compile unchanged.
  - `public let operations: FileOperationCenter`.
  - `public func selectAfterOperation(_ urls: [URL]) async`: if any of `urls` is in the current folder and no navigation happened meanwhile, it reloads and sets `selection` to those items, spelled as in `items`.
- **Behavior:**
  - `rename` calls `operations.recordRename(from:to:)` after it succeeds. `createFolder` and `createEmptyFile` call `operations.recordCreated(_:isFolder:)`.
  - The model observes `FileOperationCenter.foldersDidChange`, the same way it observes unmounts, and reloads when a listed folder is its `currentURL` (compare resolved paths). This also refreshes sizes of files that were still growing when the watcher fired.

- [ ] **Step 1: Write the failing tests**
  - `renameAndCreateAreUndoable`:
    - `createEmptyFile` sets `operations.undo.undoTitle == "New File"`;
    - after `rename(created, to: "x.txt")`, it is `"Rename"`;
    - `performUndo()` twice leaves the folder empty, with the file in the injected test trash.
  - `operationInCurrentFolderReloads`: with the model in `tmp/dst`, `operations.transfer([tmp/src/a.txt], into: tmp/dst, …)` makes `waitUntil { model.items.map(\.name) == ["a.txt"] }` true in under 0.15 s, without waiting for the watcher.
  - `selectAfterOperationSelectsItems`: after a duplicate, `selectAfterOperation(result.completed.map(\.destination))` leaves `selection` containing exactly the item URL of `a copy.txt`.
- [ ] **Step 2: Run** `scripts/test.sh --filter BrowserModel`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** Wire the shared instances in `MacCommanderApp`.
- [ ] **Step 4: Run** `scripts/test.sh`, then `scripts/build-app.sh`. Expected: all tests pass and the app builds.
- [ ] **Step 5: Commit** `feat(core): undo for rename/create; reload and select after operations`

---

### Task 9: Edit commands, the conflict dialog and the progress strip

**Files:**
- Create: `Sources/MacCommander/Operations/ConflictPrompter.swift`, `Sources/MacCommander/Operations/OperationsStrip.swift`, `Sources/MacCommander/Operations/FileActions.swift`
- Modify: `FileOutlineView.swift`, `FileListController*.swift`, `App/BrowserCommands.swift`, `Browser/BrowserWindow.swift`

**Interfaces:**
- Consumes:
  - `selectedItems` (Task 2);
  - `FileOperationCenter`, `FileClipboard` and `BrowserModel.selectAfterOperation` (Tasks 6–8).
- Produces:
  - `@MainActor enum FileActions`. Every entry point shows its errors in one alert.
    - `copy(_ items: [FileItem], clipboard:)`
    - `cut(_:clipboard:)`
    - `paste(into: URL, forceMove: Bool, model:, clipboard:, window: NSWindow?)`
    - `duplicate(_:model:)`
    - `moveToTrash(_:model:)`
    - `undo(model:)`
    - `transfer(_ urls: [URL], into: URL, mode:, model:, window:)`: used by paste and by drops in Task 12.
  - `final class ConflictPrompter`: `func resolver(for window: NSWindow?) -> ConflictResolver`.
- **Responder-chain actions on `FileOutlineView`**, forwarded to the controller:
  - The standard selectors `copy(_:)`, `cut(_:)` and `paste(_:)` (the SwiftUI default Edit menu sends them), and `undo(_:)`.
  - New `@objc` actions: `pasteAsMove(_:)`, `duplicate(_:)`, `moveToTrash(_:)`, `getInfo(_:)` (a stub until Task 11) and `copyPath(_:)` (Task 10).
  - `validateMenuItem(_:)`:
    - `undo:` is enabled only when `undoTitle != nil`, and its title is set to `Undo <title>`;
    - copy, cut, duplicate and trash need a selection;
    - paste needs `fileURLs` to be non-empty.
- **`BrowserCommands`:** add menu items that send these selectors with `NSApp.sendAction(_:to:nil,from:nil)`, like the existing ⌘O:
  - File menu: Duplicate ⌘D, Move to Trash ⌘⌫, Get Info ⌘I.
  - Edit menu, after `.pasteboard`: "Move Item Here" ⌥⌘V, Copy Path ⌥⌘C.
  - A text field with focus (Go to Folder, rename) keeps its own copy/paste/undo, because the field editor comes first in the chain.
- **Paste destination:**
  - From the menu bar: the current folder.
  - From the context menu: a single folder row means into that folder; anything else means the current folder (Task 10).
  - After paste and duplicate, `selectAfterOperation` selects the results.
- **Conflict dialog.** An `NSAlert` sheet on the window. If several conflicts arrive at the same time, they are serialized and wait for each other.
  - Message: `An item named “<name>” already exists in this location.`
  - Informative text: `Do you want to replace it with the one you’re copying?` (or `moving`).
  - Buttons, in this order: **Keep Both** (default), **Replace**, **Skip**, **Stop**. `Esc` = Stop.
  - Suppression button `Apply to All`, shown only when `moreItemsFollow`.
- **Failure alerts.**
  - `.intoItself`: `“<name>” can’t be copied into itself.` (or `moved`)
  - `.failed`: `“<name>” couldn’t be copied: <message>`
  - Trash failures: `“<name>” couldn’t be moved to the Trash: <message>`. This also covers volumes without a Trash, and the item stays where it is.
- **Progress strip.** Placed at the bottom of `BrowserWindow`'s detail area and shown while `operations` is non-empty. Each row shows:
  - the title;
  - a determinate `ProgressView` when `totalBytes > 0`, otherwise an indeterminate one;
  - `<completed> of <total>` using `ByteCountFormatter`;
  - a cancel button (`xmark.circle.fill`) calling `cancel(id)`.
  To avoid flicker, a row appears only after its operation has run for 0.5 s.

- [ ] **Step 1: Implement** `FileActions`, `ConflictPrompter`, `OperationsStrip`, the outline-view actions and the commands. These are UI files, so there are no unit tests. Core behavior is already covered.
- [ ] **Step 2: Verify.** `scripts/test.sh` passes and `scripts/build-app.sh --open` builds. Then, by hand:
  1. ⌘C a file, then ⌘V into another folder: a copy appears and is selected. ⌘V in the same folder gives `name copy.ext`.
  2. ⌘X then ⌘V moves. A second ⌘V copies.
  3. ⌘C in Finder, then ⌘V in MacCommander copies, and the reverse works too.
  4. ⌥⌘V moves.
  5. Paste onto an existing name shows the dialog, and Keep Both / Replace (the old file is in the Trash) / Skip / Stop each behave as labelled. With 3 conflicts, "Apply to All" appears.
  6. ⌘D duplicates. ⌘⌫ trashes. ⌘Z after each action reverses it, and the Edit menu shows `Undo Move to Trash` and so on.
  7. Copy a large file (≥ 2 GB from an external disk, or `mkfile 3g /tmp/big` onto a USB stick): the strip shows progress, Cancel stops it, and the partial copy is gone.
  8. In ⇧⌘G's text field, ⌘C/⌘V copy and paste text, not files.
- [ ] **Step 3: Commit** `feat: copy, cut, paste, duplicate, trash and undo with conflict dialog and progress`

---

### Task 10: Complete context menus, Open With, Compress, Copy Path, Reveal in Finder

**Files:**
- Create: `Sources/MacCommander/Operations/OpenWithMenu.swift`
- Modify: `FileList/FileContextMenu.swift`, `FileOutlineView.swift` (`copyPath(_:)`)

**Interfaces:**
- Consumes: `FileActions` (Task 9), `FileOperationCenter.compress` (Task 6).
- Produces:
  - `OpenWithMenu.make(for urls: [URL]) -> NSMenuItem` builds the "Open With" item and its submenu.
  - The submenu content:
    - first, the default app (from `NSWorkspace.urlForApplication(toOpen:)`) with the suffix ` (default)`;
    - then a separator;
    - then the other apps, sorted by display name with duplicates removed. For several items, these are the apps common to all of them (`urlsForApplications(toOpen:)` on each URL, intersected);
    - finally a separator and `Other…`, which opens an `NSOpenPanel` in `/Applications` limited to `.application`.
  - Opening calls `NSWorkspace.shared.open(urls, withApplicationAt:configuration:)`.
- **Item menu order** (spec §2.1, minus Tags ▸, which comes in Plan 6):
  - Open, Open With ▸, Quick Look
  - — Rename, Duplicate
  - — Copy, Cut, Paste (in the clicked folder when a single folder was clicked, otherwise the current folder), Move to Trash
  - — Compress “x” / Compress N Items
  - — Get Info, Copy Path, Reveal in Finder
  - — New Folder, New Empty File (already present)
- **Empty-space menu** (spec 2.2.3): New Folder, New Empty File, Paste, — Sort By ▸, Show Hidden Files, Show Checkbox Column, — Get Info (for the current folder).
- **Copy Path:** the POSIX paths of `items`, joined with `\n`, as a plain string on `NSPasteboard.general`.
- **Reveal in Finder:** `NSWorkspace.shared.activateFileViewerSelecting(urls)`.
- **Compress:** goes through the center. When it finishes, `selectAfterOperation([zip])`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** `scripts/test.sh` passes, then `scripts/build-app.sh --open`. By hand:
  1. Right-click a `.md` file → Open With lists the default app first. Other… lets you choose TextEdit and opens the file with it.
  2. Compress one folder gives `Folder.zip`. Three files give `Archive.zip`, which opens in Archive Utility. ⌘Z removes the zip.
  3. Copy Path, pasted into Terminal, gives the path.
  4. Reveal in Finder selects the item in Finder.
  5. The empty-space menu has Paste and Get Info.
- [ ] **Step 3: Commit** `feat: full context menus, Open With, Compress, Copy Path, Reveal in Finder`

---

### Task 11: Get Info

**Files:**
- Create: `Sources/MacCommanderCore/FileSystem/FolderSizeCalculator.swift`, `Sources/MacCommander/Info/InfoWindow.swift`
- Modify: `App/MacCommanderApp.swift` (`WindowGroup(id: "info", for: URL.self)`), `FileOutlineView`/controller `getInfo(_:)`, `FileContextMenu` (Get Info items)
- Test: `Tests/MacCommanderCoreTests/FolderSizeCalculatorTests.swift`

**Interfaces:**

```swift
public struct FolderSize: Sendable, Equatable { public var bytes: Int64; public var items: Int }
public enum FolderSizeCalculator {
    /// Sums regular-file sizes (logical, `.fileSizeKey`) under `url` without following symlinks;
    /// `items` counts files and folders below `url`. Throws CancellationError when cancelled.
    @concurrent public static func size(of url: URL) async throws -> FolderSize
}
```

- **Info window:** one window per item. Opening ⌘I with 3 items selected opens 3 windows; with nothing selected it opens the current folder.
  - The window's content:
    - an icon (`NSWorkspace.icon(forFile:)`, 64 pt) and the name;
    - Kind;
    - Size: for files, `ByteCountFormatter` plus the exact byte count; for folders, `Calculating…`, then e.g. `1.2 GB on disk for 3,412 items` with the exact bytes. It is computed in a `.task` and cancelled when the window closes;
    - Created and Modified dates, formatted as `Date.FormatStyle(date: .long, time: .shortened)`;
    - Where: the parent path, selectable text.
  - Read-only. The window title is `<name> Info`.
  - The controller gets `openInfo: (URL) -> Void` from `FileListView`, which reads `openWindow` from the environment.

- [ ] **Step 1: Write the failing tests**
  - `sumsFilesRecursively`: `a.txt` (3 bytes) plus `dir/b.txt` (5 bytes) gives `FolderSize(bytes: 8, items: 3)`, since the items are `a.txt`, `dir` and `dir/b.txt`.
  - `doesNotFollowSymlinks`: with `link → /usr`, the result is unchanged except that the link counts as one item of 0 bytes.
  - `cancellationThrows`: running on a folder of 20,000 empty files inside a `Task` that is cancelled immediately throws `CancellationError`.
- [ ] **Step 2: Run** `scripts/test.sh --filter FolderSizeCalculator`. Expected: FAIL.
- [ ] **Step 3: Implement** the calculator and the window.
- [ ] **Step 4: Verify.** `scripts/test.sh` passes, then `scripts/build-app.sh --open`. ⌘I on a file, on a large folder (Calculating… then a size) and on empty space (the current folder) shows correct info, and closing a window stops its calculation.
- [ ] **Step 5: Commit** `feat: Get Info window with on-demand folder size`

---

### Task 12: Drag and drop

**Files:**
- Modify: `FileList/FileListController+Outline.swift` (drag source and destination), `FileList/FileOutlineView.swift`, `Sidebar/SidebarView.swift`

**Interfaces:**
- Consumes:
  - `DropPolicy.operation` (Task 7);
  - `FileActions.transfer` (Task 9);
  - the existing pasteboard writer (`NSURL` per row).
- **Drag source.** Call `setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)` and the same with `forLocal: true`. Dragging to Finder, the Desktop or other apps works through file URLs.
- **Drop target in the list.** `registerForDraggedTypes([.fileURL])`.
  - In `validateDrop`:
    - over a folder row, drop on that row;
    - over a file row or empty space, retarget to the current folder with `setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)`.
  - The destination is either the folder row or `model.currentURL`. Modifiers come from `NSEvent.modifierFlags`. `DropPolicy` returning nil refuses the drop (no highlight). Otherwise the operation is `.move` or `.copy`, and the cursor shows the matching badge.
  - `acceptDrop` calls `FileActions.transfer` and returns true. The transfer runs asynchronously, with conflicts as in Task 9.
- **Sidebar.**
  - Dropping **between** Favorites rows keeps adding favorites (the existing `.onInsert`).
  - Dropping **onto** a Favorites folder row or a Locations volume row moves or copies into it with the same policy. Use `.dropDestination(for: URL.self)` on the row, or an `onDrop` delegate if the destination needs the modifier keys: `NSEvent.modifierFlags` at drop time.
  - If SwiftUI can't keep the between and onto drops apart reliably, onto-row drops win, and adding favorites moves to the Favorites section header plus the existing "Add to Favorites" path. Record this as a ruling.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** `scripts/test.sh` passes, then `scripts/build-app.sh --open`. By hand:
  1. Dragging a file onto a folder row moves it, and ⌘Z moves it back. ⌥-drag copies (a green + badge).
  2. Dragging onto a USB-stick folder copies.
  3. Dragging a folder onto itself or its own child is refused.
  4. Dragging from MacCommander to the Desktop or Finder moves the file (same volume). Dragging from Finder into the list or onto empty space copies or moves into the current folder.
  5. Dragging onto a Favorites row moves into that folder. Dragging between rows adds a favorite.
  6. The progress strip and conflict dialog appear for drops, just as for paste.
- [ ] **Step 3: Commit** `feat: drag and drop within the list, sidebar and to/from Finder`

---

## Self-review notes
- **Spec coverage, §2.1 File operations:**
  - copy, cut/move and paste → T9
  - duplicate → T6/T9; rename → Plan 1 + undo in T8
  - trash → T5/T9; compress → T6/T10
  - open with default app → Plan 1; Open With ▸ → T10
  - progress and cancel → T4/T6/T9; conflict dialog → T4/T9
  - undo for all listed actions → T5/T8/T9
- **Spec coverage, other §2.1 items:**
  - drag and drop → T12
  - keyboard ⌘⌫ ⌘C ⌘V ⌥⌘V ⌘D → T9
  - Get Info → T11. Tags editing is in Plan 6.
  - context menu → T10, without Tags ▸ (Plan 6)
  - Copy Path and Reveal in Finder → T10
- **Spec §4:** Replace trashes the existing item. A cross-volume move deletes the source only after its copy succeeded, and Review Focus 1–5 pin these rules.
- **Deliberately not in this plan:**
  - Redo, because spec §2.1 lists undo only.
  - Folder "Merge" on conflict, because the spec lists Replace / Keep Both / Skip / Stop.
  - File-promise drops from Mail or browsers.
  - Live size updates for files written by other apps (FSEvents file events). Plan 6 polish.
