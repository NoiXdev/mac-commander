# MacCommander Plan 3: Archives as Folders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-clicking an archive (zip, tar, tgz, 7z, rar, …) opens it like a folder. The path bar shows `… › assets.zip › images`, back and forward work, and inner folders expand inline. Selected entries can be extracted through the context menu or by dragging them out, and the whole archive can be extracted. Quick Look and Open work on entries. Encrypted archives ask for a password. Archives are read-only.

**Architecture:**
- **Virtual URLs.** A location inside an archive is a virtual file URL: the archive file's path, followed by the path inside the archive (`/…/assets.zip/images`). The archive root is the archive file's own URL. History, path bar, window restore and `currentURL` keep working unchanged. Writes under such a path fail safely with ENOTDIR.
- **Detection.** `ArchivePath.split` finds the archive by locating the first path component that is a regular file.
- **Listing.** `ArchiveCatalog`, an app-wide actor, lists an archive once with `bsdtar --format=mtree` and caches an index keyed by path, size and mtime. It answers the folder listings that `BrowserModel.load` and `children(of:)` request.
- **Extraction.** bsdtar extracts into a private staging folder next to the destination. The extracted items are then moved into place with the Plan 2 `FileTransfer` engine, so the conflict dialog, progress and undo come for free.
- **Drag-out.** Dragging out uses `NSFilePromiseProvider` for Finder. Drops inside the app use a custom pasteboard type.

**Tech Stack:** Swift 6, SwiftUI, AppKit, `/usr/bin/bsdtar` (libarchive 3.7.4 on macOS 15), Swift Testing, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-17-maccommander-design.md` (§2.2.5 Archives as folders, §7 "One list, many sources" and "Archives", §4 anti-goals).

### Roadmap position
Plan 3 of 6. Plans 1 and 2 are done. Next: Plan 4 (preview and Markdown), Plan 5 (network shares), Plan 6 (tags, search, iCloud, Settings, icon).

## Global Constraints
- macOS 15, Swift 6. Toolchain is CLT only: run `scripts/test.sh`, use Swift Testing, and don't use the `@State`/`@Entry` macros. Use `State<T>` properties and hand-written keys, as the existing code does. Never touch the real Trash in tests.
- Archives use the system `/usr/bin/bsdtar`, with no bundled archive library (spec §5). bsdtar always runs off the main thread as a child process, through `ProcessRunner` (Task 1), with:
  - **stdin = `/dev/null`**;
  - **always `--passphrase <value>`**, with a random placeholder when no password is known. Without these, bsdtar loops forever on an "Enter passphrase:" prompt;
  - `--no-same-owner` on extraction;
  - never `-P`, since bsdtar's defaults refuse `..`, strip leading `/` and guard symlinks.
- Pure archive extensions, fixed by spec §2.2.5: `zip, tar, tgz, tar.gz, tbz, tbz2, tar.bz2, txz, tar.xz, 7z, rar`. Only these open as folders on double-click or ⌘↓.
- "Browse Contents" appears in the context menu for the pure archive extensions above, plus the zip-based and system containers bsdtar can read: `docx, xlsx, pptx, odt, ods, odp, pages, numbers, key, epub, jar, ipa, apk, xpi, pkg, xar, iso, cpio`. `.dmg` and `.app` are excluded, because bsdtar can't read them.
- Archives are **read-only** (spec §3). Inside an archive:
  - These are disabled: rename, new folder or file, cut, copy, paste, duplicate, Move to Trash, compress, Get Info, and dropping into the list.
  - These are available: Open, Quick Look, Extract, Extract All… and drag-out.
- Spec §4 data safety applies to extraction:
  - Extraction never overwrites silently: conflicts use the Plan 2 dialog.
  - It never writes outside the chosen destination.
  - Only the operation's own staging folder is ever deleted permanently.
- Encrypted archives prompt for a password. The password is **kept in memory for the app session only**, never written to disk or the Keychain (spec "not stored").
- UI strings in English via `String(localized:)`. Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on `main`, without worktrees.

## Review Focus
1. **Hostile entry names** never write outside the destination: `../../evil`, `/etc/x`, and a symlink entry `l → /tmp` followed by `l/x`. Pinned in Task 4.
2. **Names with glob characters, spaces, umlauts (NFD) or newlines** (`st*r [x].txt`, `Ärger\nneu.md`) list correctly and extract exactly that one entry. Pinned in Tasks 2 and 4.
3. **Encrypted archives** never hang, and a wrong password asks again. Partial output from a failed attempt never reaches the destination. Pinned in Tasks 4 and 5.
4. **A corrupt or truncated file, or a non-archive named `.zip`**, leads to a clear error or the default-app fallback, never a crash or an endless spinner. Pinned in Tasks 2 and 5.
5. **An archive that is deleted or replaced while it is open** falls back to its parent folder, or re-lists the archive. Navigating inside a 100,000-entry archive doesn't re-run bsdtar for every folder. Pinned in Tasks 2 and 5.

---

## File Structure

```
Sources/MacCommanderCore/
  System/ProcessRunner.swift              async child process: stdout/stderr capture, cancel (Task 1)
  Operations/Compressor.swift             refactored onto ProcessRunner (Task 1)
  Archives/ArchiveFormats.swift           extension lists, isArchive / isBrowsable (Task 2)
  Archives/ArchiveIndex.swift             mtree parser + per-folder index → [FileItem] (Task 2)
  Archives/ArchiveCatalog.swift           actor: list via bsdtar, cache, passwords (Task 2)
  Archives/ArchivePath.swift              split / join virtual URLs (Task 3)
  Navigation/PathUtilities.swift          nearestExistingAncestor returns folders only (Task 3)
  Archives/ArchiveExtractor.swift         bsdtar -x into staging, pattern escaping (Task 4)
  Operations/FileOperationCenter.swift    + extract / extractAll (Task 4)
  Browser/BrowserModel.swift              archive locations in load/children/open/watch (Task 5)
  FileSystem/DirectoryLoader.swift        DirectoryLoadError gains archive cases (Task 5)
  Archives/ArchivePreviewCache.swift      temp extraction for Quick Look / Open (Task 7)
Sources/MacCommander/
  FileList/*                              read-only gating, icons, menus (Task 6), QL/Open (Task 7), drag-out/in (Task 8)
  Archives/ArchivePasswordSheet.swift     password prompt (Task 6)
  Operations/FileActions.swift            extract actions (Task 6), promise/internal drops (Task 8)
  Sidebar/SidebarView.swift               accepts internal archive drags (Task 8)
Tests/MacCommanderCoreTests/
  ProcessRunnerTests, ArchiveIndexTests, ArchiveCatalogTests, ArchivePathTests,
  ArchiveExtractorTests, BrowserModelArchiveTests, ArchivePreviewCacheTests, ArchiveFixtures.swift
```

Test fixtures are built at test time with `/usr/bin/bsdtar -c` (formats `zip`, `ustar`, `pax`, plus `-z`) and `/usr/bin/zip -P` (encrypted zip), from a `TemporaryDirectory`. A helper in `ArchiveFixtures.swift` builds them: `makeArchive(_ files: [String: String], format: String, in: TemporaryDirectory) throws -> URL`. Values ending in `"→"` + target denote symlinks.

---

### Task 1: `ProcessRunner`

**Files:** Create `Sources/MacCommanderCore/System/ProcessRunner.swift`, `Tests/MacCommanderCoreTests/ProcessRunnerTests.swift`. Modify `Operations/Compressor.swift` to use the runner, with no behavior change.

**Interfaces:**
```swift
public struct ProcessOutput: Sendable { public let status: Int32; public let stdout: Data; public let stderr: String }
public enum ProcessRunner {
    /// Runs `executable` with stdin = /dev/null. Drains stdout and stderr concurrently (no pipe deadlock),
    /// and returns once the process has exited and both pipes have reached EOF. Task cancellation
    /// terminates the process and throws `CancellationError`.
    @concurrent public static func run(_ executable: URL, _ arguments: [String], currentDirectory: URL? = nil) async throws -> ProcessOutput
}
```
Move Compressor's existing launch, drain and cancel logic here; don't rewrite it.

- [ ] **Step 1: Write the failing tests:**
  - `capturesStdoutAndStatus`: `/bin/echo hi` gives `stdout == "hi\n"` and `status == 0`.
  - `capturesStderrAndFailure`: `/bin/sh -c "echo oops >&2; exit 3"` gives `status == 3` and `stderr == "oops\n"`.
  - `largeOutputDoesNotDeadlock`: `/bin/sh -c "head -c 5000000 /dev/zero; head -c 200000 /dev/zero >&2"` gives `stdout.count == 5_000_000`.
  - `stdinIsEmpty`: `/bin/cat` returns immediately with empty stdout.
  - `cancellationTerminates`: `/bin/sleep 30` in a Task, cancelled after 0.2 s, throws `CancellationError` within 2 s.
- [ ] **Step 2: Run** `scripts/test.sh --filter ProcessRunner`. Expected: FAIL (the type doesn't exist).
- [ ] **Step 3: Implement it.** Then port Compressor onto it.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: everything passes, including the existing Compressor tests.
- [ ] **Step 5: Commit** `refactor(core): ProcessRunner for child processes; Compressor uses it`

---

### Task 2: Archive formats, index and catalog

**Files:**
- Create in `Sources/MacCommanderCore/Archives/`: `ArchiveFormats.swift`, `ArchiveIndex.swift`, `ArchiveCatalog.swift`.
- Tests: `ArchiveIndexTests.swift`, `ArchiveCatalogTests.swift`, `ArchiveFixtures.swift`.

**Interfaces:**
```swift
public enum ArchiveFormats {
    public static func isArchive(_ url: URL) -> Bool      // pure list (Global Constraints), compound "tar.gz" etc. matched case-insensitively
    public static func isBrowsable(_ url: URL) -> Bool    // pure list + container list
}

public struct ArchiveEntry: Sendable, Equatable { public let path: String; public let isDirectory: Bool; public let isSymlink: Bool; public let size: Int64?; public let modified: Date? }

public struct ArchiveIndex: Sendable {
    /// Parses `bsdtar -cf - --format=mtree --options='!all,type,size,time' @archive` output.
    public init(mtree: String)
    public func entries(in folder: String) -> [ArchiveEntry]?   // "" = root; nil = no such folder
    public var entryCount: Int { get }
}

public enum ArchiveError: Error, Equatable, Sendable {
    case passwordRequired, incorrectPassword
    case unsupported(message: String)     // bsdtar: "Unrecognized archive format" / "not supported"
    case unreadable(message: String)      // any other bsdtar failure
}

public actor ArchiveCatalog {
    public static let shared: ArchiveCatalog
    public init(bsdtar: URL = URL(fileURLWithPath: "/usr/bin/bsdtar"))
    /// Index for `archive`, listed once per (path, size, mtime). Uses the session password if one is set.
    public func index(of archive: URL) async throws(ArchiveError) -> ArchiveIndex
    /// FileItems of `folder` inside `archive`, URLs = ArchivePath virtual URLs (Task 3 defines `ArchivePath.url(archive:inner:)`;
    /// until then build `archive.appendingPathComponent(inner)`), hidden rules applied.
    public func items(in folder: String, of archive: URL, includeHidden: Bool) async throws(ArchiveError) -> [FileItem]
    public func setPassword(_ password: String, for archive: URL)
    public func password(for archive: URL) -> String?
    public func invalidate(_ archive: URL)
}
```

**Index rules:**
- Decode mtree escapes: `\ooo` octal bytes, decoded as UTF-8, and `\\`. Strip the leading `./`. Skip the `.` and `/.` roots.
- Skip entries with an empty name, a `..` component or a leading `/`, which remains after stripping.
- Folders that appear only as parents of entries (common in zips) are synthesized.
- With duplicate names, the last one wins.
- `type=link` counts as a symlink file, not a folder. `size` applies to files only.
- Names are compared as Unicode-normalized NFC keys. The display name keeps the original form.

**FileItem rules:**
- `name` is the last path component. `isDirectory` comes from the entry. `isPackage` is false. `size` is nil for folders. `dateModified` comes from `time`.
- `kind` is `UTType(filenameExtension:)?.localizedDescription`, `"Folder"` for folders, or `"Document"` otherwise.
- `isHidden` is true for names starting with `.` and for `__MACOSX` at any depth. Both are shown only when `includeHidden` is true.

**Catalog:**
- Runs `bsdtar -cf - --format=mtree --options=!all,type,size,time --passphrase <pw or random UUID> @<archive>` through `ProcessRunner`.
- Maps stderr to errors:
  - "passphrase" (case-insensitive) with no session password gives `.passwordRequired`; with a session password, `.incorrectPassword`.
  - "Unrecognized archive format" or "not supported" gives `.unsupported`.
  - Any other non-zero exit gives `.unreadable`.
- Caches at most 8 indexes, evicting the least recently used. A cancelled caller cancels the bsdtar run.

- [ ] **Step 1: Write the failing tests.**
  - **Index tests** use literal mtree strings:
    - `parsesFilesFoldersAndSymlinks`: the four-line sample from bsdtar (`./a\040b.txt … type=file size=3`, `./sub type=dir`, `./sub/link type=link`, `./sub/\303\204rger\012neu.md`). Root gives `["a b.txt", "sub"]`. `sub` gives `["link", "Ärger\nneu.md"]`, and `link` has `isSymlink`.
    - `synthesizesMissingFolders`: a single line `./x/y/z.txt type=file size=1` makes `entries(in: "")` return the folder `x` and `entries(in: "x/y")` return `z.txt`.
    - `skipsUnsafeAndRootEntries`: `/. type=dir`, `./../evil type=file`, `./a/../../b type=file` and `./ok type=file` produce a root containing only `ok`.
    - `nfdAndNfcAreOneEntry`: `./A\314\210rger type=file` followed by `./\303\204rger type=file` makes `entryCount == 1`.
    - `parsesTwentyThousandEntriesQuickly`: a generated mtree with 20,000 lines across 200 folders parses in under 1.0 s.
  - **Catalog tests** use real bsdtar fixtures:
    - `listsZipAndTgz`: the same tree as zip and as `-z` ustar gives an identical root and subfolder listing.
    - `hiddenAndMacosxFiltered`: `.DS_Store` and `__MACOSX/x` are hidden unless `includeHidden`.
    - `encryptedZipNeedsPassword`, using `zip -P secret`:
      - the listing either succeeds, because zip headers aren't encrypted, or throws `.passwordRequired`, and never hangs: wrap it in a 10 s timeout;
      - after `setPassword("wrong")` it still never hangs.
    - `notAnArchiveIsUnsupportedOrUnreadable`: a text file named `x.zip` throws `.unsupported` or `.unreadable`.
    - `cacheReusedUntilFileChanges`: a second `index` call doesn't run bsdtar. Count runs through an internal `runCount`. After the file is rewritten (mtime and size change), it re-lists.
    - `formatLists`:
      - `isArchive` is true for `a.TAR.GZ`, false for `a.docx` and false for `a.dmg`;
      - `isBrowsable` is true for `a.docx` and false for `a.dmg`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "ArchiveIndex|ArchiveCatalog"`. Expected: FAIL.
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: everything passes.
- [ ] **Step 5: Commit** `feat(core): archive index from bsdtar mtree listing, cached catalog`

---

### Task 3: `ArchivePath` and folder-only fallback

**Files:** Create `Sources/MacCommanderCore/Archives/ArchivePath.swift`, `Tests/MacCommanderCoreTests/ArchivePathTests.swift`. Modify `Navigation/PathUtilities.swift` and the catalog's URL building from Task 2.

**Interfaces:**
```swift
public struct ArchiveLocation: Hashable, Sendable { public let archive: URL; public let inner: String }   // inner "" = root, no leading/trailing "/"
public enum ArchivePath {
    /// The archive location `url` points into: the first path component that is an existing regular file
    /// (symlinks resolved), with the rest as `inner`. nil for ordinary paths. Plain `stat`s only, cheap.
    public static func split(_ url: URL) -> ArchiveLocation?
    public static func url(archive: URL, inner: String) -> URL
}
```
- **`split` examples:** `…/a.zip` gives `(a.zip, "")`. `…/a.zip/img/x` gives `(a.zip, "img/x")`. `…/folder/sub` gives nil.
- **`nearestExistingAncestor`:**
  - It now returns the nearest existing **directory**, which was deferred from Plan 1.
  - For a path inside an archive whose archive file is gone, it returns the archive's parent folder.
  - For a path inside a still-existing archive, it returns the archive's parent folder too. Callers decide whether to browse the archive.

- [ ] **Step 1: Write the failing tests:**
  - `splitFindsArchiveRootAndInner`
  - `splitIgnoresOrdinaryFolders`
  - `splitThroughSymlinkedFolder`: a symlink to a folder is not treated as an archive.
  - `urlRoundTrips`
  - `nearestAncestorSkipsFiles`: for `…/file.txt/x`, the parent of `file.txt` is returned.
- [ ] **Step 2: Run** `scripts/test.sh --filter "ArchivePath|PathUtilities"`. Expected: FAIL.
- [ ] **Step 3: Implement it.** Switch the catalog's URL building to `ArchivePath.url`.
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: everything passes, including the existing PathUtilities tests. Adjust only an assertion that encoded the old file-returning behavior, and say so in the report.
- [ ] **Step 5: Commit** `feat(core): virtual archive paths; nearest existing ancestor is a folder`

---

### Task 4: Extraction

**Files:** Create `Sources/MacCommanderCore/Archives/ArchiveExtractor.swift`, `Tests/MacCommanderCoreTests/ArchiveExtractorTests.swift`. Modify `Operations/FileOperationCenter.swift` and its tests.

**Interfaces:**
```swift
public enum ArchiveExtractor {
    /// Extracts `entries` (paths inside the archive, "" = everything) into a new hidden staging folder
    /// `<destination>/.mc-partial-<UUID>` and returns the staged top-level items: for each requested entry
    /// the item at `staging/<entry>`, or for "" every top-level item of the staging folder.
    /// The caller moves them and must call `removeStaging`. On error, staging is removed before throwing.
    @concurrent public static func stage(_ entries: [String], from archive: URL, near destination: URL, password: String?) async throws -> (staging: URL, items: [URL])
    public static func removeStaging(_ staging: URL)
    /// bsdtar pattern for an entry: `*`, `?`, `[`, `\` escaped with a backslash.
    static func pattern(for entry: String) -> String
}
extension FileOperationCenter {
    /// Stage, then `FileTransfer.run(items, into: destination, mode: .move, resolver:)`, then remove staging.
    /// Pushes `.created(completed destinations)` titled "Extract" (`Extract of “a.png”` / `Extract of 3 Items` isn't needed: use "Extract").
    /// Posts foldersDidChange for destination. Shows as an operation with title `Extracting “a.png”` / `Extracting 3 items`.
    public func extract(_ entries: [String], from archive: URL, into destination: URL, resolver: @escaping ConflictResolver) async throws -> TransferResult
    /// Whole archive into `destination`: one top-level item → as is; several → into a new folder named after the archive
    /// without its archive extension (`assets.tar.gz` → `assets`, keep-both naming if taken). Returns the created top-level URL(s).
    public func extractAll(_ archive: URL, into destination: URL, resolver: @escaping ConflictResolver) async throws -> TransferResult
}
```
- **bsdtar invocation:** `bsdtar -x -f <archive> -C <staging> --no-same-owner --passphrase <pw or random> -- <patterns…>`, run through `ProcessRunner`. Map password errors as in Task 2. Pass the password from `ArchiveCatalog.shared.password(for:)`, which the center reads.
- **Folder entries:** a folder entry extracts its whole subtree, because a bsdtar pattern on a folder matches its contents.
- **Cancellation:** cancelling terminates bsdtar and removes staging. A cancelled extraction shows no alert, as in Plan 2.

- [ ] **Step 1: Write the failing tests** (real bsdtar fixtures; a fake trash where the center needs one).
  - `extractsSelectedEntryOnly`: from a zip with `img/a.png`, `img/b.png` and `c.txt`, extracting `img/a.png` leaves `dst` containing only `a.png`, with the right content. No staging folder remains.
  - `extractsFolderEntryWithContents`: `img` gives `dst/img/a.png` and `dst/img/b.png`.
  - `globAndSpecialNames`: the entries `st*r [x].txt`, `stXr x.txt` and `Ärger neu.md`. Extracting `st*r [x].txt` gives exactly that file.
  - `hostileEntriesStayInside`: a pax archive with `../evil` and `/abs/x` (use `bsdtar -c -P -s` substitutions to plant them), plus symlink `l → <tmp outside>` followed by the entry `l/x`. After extract-all, nothing exists outside `dst`, and the outside directory is unchanged.
  - `encryptedZip`:
    - without a password, it throws `.passwordRequired` and `dst` stays empty;
    - with the wrong password, it throws `.incorrectPassword` and `dst` stays empty (no partial files);
    - with `secret`, it extracts.
  - `conflictUsesResolver`: when `dst/c.txt` exists and the resolver returns `.keepBoth`, the result is `c 2.txt`. The undo title is `"Extract"`. Undo trashes the extracted file.
  - `extractAllSingleVsMultiple`:
    - an archive with one top folder `assets/…` gives `dst/assets`;
    - an archive with loose files, `x.tar.gz`, gives `dst/x/…`;
    - when `dst/x` already exists, it gives `dst/x 2`.
  - `cancelRemovesStaging`: a large tgz (30 MB of random data); cancel right after it starts. Expect `CancellationError` and no `.mc-partial-*` left in `dst`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "ArchiveExtractor|FileOperationCenter"`. Expected: FAIL.
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: everything passes. Run the filter 3 times to make sure it isn't flaky.
- [ ] **Step 5: Commit** `feat(core): extract archive entries via staging and the transfer engine`

---

### Task 5: Browsing archives in `BrowserModel`

**Files:** Modify `Sources/MacCommanderCore/Browser/BrowserModel.swift` and `FileSystem/DirectoryLoader.swift` (`DirectoryLoadError`). Test: `Tests/MacCommanderCoreTests/BrowserModelArchiveTests.swift`.

**Interfaces:**
- `BrowserModel.init(…, catalog: ArchiveCatalog = .shared)`, a new last parameter with a default.
- `public private(set) var archiveLocation: ArchiveLocation?`: nil in ordinary folders. It is updated together with `items`/`listedURL`, and the UI derives read-only mode from it.
- `public func browseContents(_ item: FileItem) async`: navigates into any browsable file, including `.docx`.
- `public func providePassword(_ password: String) async`: calls `catalog.setPassword` for the current archive, then reloads.
- `DirectoryLoadError` gains `archivePasswordRequired(URL)`, `archiveIncorrectPassword(URL)` and `archiveUnreadable(URL, String)`. `message` gains these texts:
  - `“x.zip” is encrypted. Enter its password to see its contents.`
  - `The password for “x.zip” is incorrect.`
  - `“x.zip” can’t be opened: <message>`
- **Behavior:**
  - **Navigation:**
    - `navigate(to:)` accepts directories as before, plus regular files where `ArchiveFormats.isArchive` is true, and any URL that `ArchivePath.split` resolves into an archive. Go to Folder `…/a.zip/img` works.
    - `open(item)`: when the current location is not an archive, a file with `isArchive` navigates into it. Inside an archive, folders navigate. Files go to the UI (Task 7), so `open` does nothing for archive files inside an archive.
  - **Loading:**
    - `load()` and `children(of:)` run `ArchivePath.split` **before** the existence check. For archive locations they use `catalog.items(in:of:includeHidden:)`.
    - If the archive file is gone, they fall back to `nearestExistingAncestor`.
    - If `inner` doesn't exist in the index, they fall back to the deepest existing inner folder.
    - Sorting and hidden filtering are the same as for folders.
  - **Unsupported archives:** for archives opened by double-click (not by Browse Contents), `.unsupported` makes the model return to the previous history entry and call `opener(archive)`, so the default app handles it (spec runtime format check). For Browse Contents, `.unsupported` and `.unreadable` both become `loadError`.
  - **Watching:** in an archive location, the watcher watches the **archive file**. A change invalidates the catalog entry and reloads. If the archive was deleted, the model falls back to the parent folder.
  - **Write operations:** `createFolder`, `createEmptyFile` and `rename` throw `CocoaError(.fileWriteNoPermission)` when `archiveLocation != nil`. This is a guard; the UI disables them anyway.

- [ ] **Step 1: Write the failing tests:**
  - `openArchiveShowsRoot`: `open(zipItem)` makes `currentURL == zip`, the items equal the root entries and `archiveLocation?.inner == ""`.
  - `navigateIntoArchiveFolderAndBack`: inside the archive, `open(folderItem)` shows the subfolder, and `goBack` shows the root.
  - `goToVirtualPath`
  - `childrenInsideArchive`
  - `encryptedNeedsPassword`, using an encrypted archive where listing needs the password. If zip headers are readable without it, test the flow with the catalog's internal error injection instead (`ArchiveCatalog(testError:)`):
    - `loadError == .archivePasswordRequired`;
    - after `providePassword("secret")`, the items show.
  - `unsupportedFallsBackToOpener`: a text file named `bad.zip` is opened through the opener, and the model stays in the parent folder.
  - `browseContentsUnreadableShowsError`
  - `archiveDeletedFallsBackToParent`, using the watcher.
  - `archiveReplacedRelists`: the archive is rewritten with a new entry, which appears.
  - `writesRefusedInsideArchive`
- [ ] **Step 2: Run** `scripts/test.sh --filter BrowserModelArchive`. Expected: FAIL.
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: everything passes, including all existing BrowserModel tests.
- [ ] **Step 5: Commit** `feat(core): browse archives as folders in BrowserModel`

---

### Task 6: UI for archive browsing and extraction

**Files:**
- Create `Sources/MacCommander/Archives/ArchivePasswordSheet.swift`.
- Modify `FileList/FileListController*.swift` (command gating, icons, load error view), `FileList/FileContextMenu.swift`, `Operations/FileActions.swift`, `App/BrowserCommands.swift`, `Browser/BrowserWindow.swift`.

**Behavior:**
- **Read-only gating.** `canPerform` returns false for every write or copy command when `model.archiveLocation != nil`. The empty-space menu then shows only Extract All…, Sort By ▸, Show Hidden Files and Show Checkbox Column. Drops into the list are refused (DropPolicy isn't consulted). Inline rename never starts.
- **Icons.** Rows inside an archive use `NSWorkspace.shared.icon(for: UTType)`: `.folder` for folders, otherwise the type from the extension, falling back to `.data`. Rows never call `icon(forFile:)` on virtual paths.
- **Password.** On `archivePasswordRequired` or `archiveIncorrectPassword`, the list area shows the error message plus a "Enter Password…" button. The button opens `ArchivePasswordSheet`: a secure field, Cancel, and Open as the default button. Open calls `model.providePassword`. A cancelled sheet leaves the message visible. The same sheet is used when an extraction throws a password error: retry after `ArchiveCatalog.shared.setPassword`.
- **Context menu on an archive file** (not inside an archive):
  - **Open**: browse.
  - **Extract All Here**: `extractAll(into: parent)`.
  - **Open with Archive Utility**: `/System/Library/CoreServices/Applications/Archive Utility.app`.
  - **The normal item actions** follow.
  - **Browse Contents** appears for files where `isBrowsable` is true and `isArchive` is false.
- **Context menu on entries inside an archive:**
  - Open and Quick Look (Task 7 wires these).
  - Then **Extract to “<archive's parent folder name>”**.
  - Then **Extract To…**: an `NSOpenPanel` with `canChooseDirectories`, `canCreateDirectories` and prompt "Extract". It runs as a sheet.
- **Empty space inside an archive:** **Extract All…**: choose a folder, then `extractAll`.
- **After extracting:** the results are selected with `selectAfterOperation` whenever the window shows the destination. Errors use the Plan 2 alert helper with `“x” couldn’t be extracted: <message>`. A cancelled extraction shows no alert.
- **Path bar and title:** the path bar needs no change, since its segments come from the virtual URL. The window title shows the last component, as before.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** `scripts/test.sh` passes and `scripts/build-app.sh` builds. Then, by hand:
  1. Double-clicking a `.zip` shows its contents, and the path bar shows `… › x.zip › folder`. ⌘[ goes back.
  2. Inside the archive, ⌘⌫, ⌘V, ⌘D, Return and ⇧⌘N do nothing, and their menu items are disabled.
  3. Extract to “Downloads” works, and a conflict shows the dialog.
  4. Extract All Here on a multi-file zip creates a folder.
  5. An encrypted zip asks for its password. A wrong password asks again.
  6. Browse Contents on a `.docx` shows `word/document.xml`.
  7. Double-clicking a corrupt `x.zip` (made with `echo hi > x.zip`) opens Archive Utility, which shows its own error.
- [ ] **Step 3: Commit** `feat: browse archives, extract entries and archives, password prompt`

---

### Task 7: Quick Look and Open for archive entries

**Files:** Create `Sources/MacCommanderCore/Archives/ArchivePreviewCache.swift` and `Tests/MacCommanderCoreTests/ArchivePreviewCacheTests.swift`. Modify `QuickLook/QuickLookController.swift`, `FileListController+QuickLook.swift`, `FileContextMenu.swift`, the open path in `FileListController+Selection.swift` and `App/MacCommanderApp.swift` (purge at launch and on quit).

**Interfaces:**
```swift
public actor ArchivePreviewCache {
    public static let shared: ArchivePreviewCache
    public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("MacCommander Previews", isDirectory: true))
    /// Extracts `entries` (files only) of `archive` into `root/<UUID per archive version>/` once and returns
    /// the extracted file URLs in the same order. Re-extracts when the archive's size or mtime changed.
    public func files(_ entries: [String], of archive: URL) async throws(ArchiveError) -> [URL]
    public func purge()
}
```
- **Quick Look:** Space on archive entries extracts the selected **files** through the cache, then shows the panel with those temporary URLs. The ← and → keys move through the extracted set. Folders are skipped. While extraction runs, the panel isn't shown yet. Pressing Space again cancels.
- **Open** (double-click, ⌘↓, ⌘O, menu Open) on a file entry: extract it through the cache, then `NSWorkspace.shared.open`. The entry was extracted to a temporary location, so edits are not written back (spec: archives are read-only).
- **Purging:** the cache is purged at launch and at `applicationWillTerminate`.
- **Password errors** go through the Task 6 sheet, then retry.

- [ ] **Step 1: Write the failing tests:**
  - `extractsOnceAndReuses`: the second call doesn't run bsdtar (internal `runCount`).
  - `reextractsAfterArchiveChanged`
  - `orderMatchesRequest`
  - `purgeRemovesRoot`
- [ ] **Step 2: Run** `scripts/test.sh --filter ArchivePreviewCache`. Expected: FAIL.
- [ ] **Step 3: Implement** the cache and the UI wiring.
- [ ] **Step 4: Verify.** `scripts/test.sh` passes. Then, by hand:
  1. Space on a `.png` inside a zip previews it, and ← → moves through the entries.
  2. Double-clicking a `.txt` entry opens it in TextEdit.
  3. After quitting, `~/…/T/MacCommander Previews` is gone.
- [ ] **Step 5: Commit** `feat: Quick Look and Open for archive entries via a temporary cache`

---

### Task 8: Drag entries out of an archive

**Files:** Modify `FileList/FileListController+Outline.swift`, `Operations/FileActions.swift` and `Sidebar/SidebarView.swift`. Create `FileList/ArchiveEntryDragProvider.swift`.

**Interfaces:**
- `final class ArchiveEntryDragProvider: NSFilePromiseProvider` is created per dragged entry row: one provider per top-level selected entry, using `PathUtilities.topLevel`.
  - It carries `(archive: URL, entry: String)`.
  - `fileType` comes from the entry's UTType, or `public.folder` for folders. `fileNameForType` returns the entry name.
- **Finder, the Desktop and other apps** use the delegate's `filePromiseProvider(_:writePromiseTo:completionHandler:)`. It calls `ArchiveExtractor.stage`, then an exclusive move into the promised URL (the `FileTransfer` exclusive rename), then removes staging. It runs on an `OperationQueue` returned by `operationQueue(for:)`, never on the main thread.
- **Inside the app**, the provider also writes the custom type `dev.noix.MacCommander.archive-entries`: a property list `{archive: path, entries: [String]}` covering all dragged entries. Override `writableTypes(for:)` and `pasteboardPropertyList(forType:)` for this.
  - The list's `validateDrop`/`acceptDrop` and the sidebar row drop delegates check this type **first**. If present, they offer `.copy` (refused inside an archive) and call `FileActions.extract(entries, from: archive, into: destination, …)`. That gives the conflict dialog, progress and undo, as in Task 6.
  - `FileActions.fileURLs` stays as it is: virtual URLs are never written as file URLs for archive rows.
- **Source operation mask** for archive rows: `.copy` only.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Verify.** `scripts/test.sh` passes and `scripts/build-app.sh` builds. Then, by hand:
  1. Dragging `img/a.png` from a zip to the Desktop creates `a.png`.
  2. Dragging an entry folder to Finder creates the folder with its contents.
  3. Dragging an entry onto a sidebar Favorite, or onto a folder in another MacCommander window, extracts it there. A conflict shows the dialog, and ⌘Z trashes the extracted item.
  4. Dragging into the same archive's list is refused.
- [ ] **Step 3: Commit** `feat: drag entries out of archives to Finder, the sidebar and other windows`

---

## Self-review notes
- **Spec §2.2.5 coverage:**
  - open like a folder, path bar, back/forward → Tasks 3 and 5;
  - inline expansion → Task 5 (`children`);
  - fixed extension list and Browse Contents → Tasks 2, 5 and 6;
  - runtime format check → Task 5 (an unsupported double-click falls back to the opener);
  - read-only → Tasks 5 and 6;
  - extract selected via menu → Tasks 4 and 6; via drag → Task 8;
  - Extract All… → Tasks 4 and 6;
  - Quick Look and Open via temporary folder → Task 7;
  - encrypted archives → Tasks 2, 4, 5 and 6;
  - archive-file menu (Open, Extract All Here, Open with Archive Utility) → Task 6.
- **Spec §7:** "One list, many sources" is implemented as virtual URLs. `BrowserModel.load` dispatches folder vs archive. Plan 6 search results become a third branch.
- **Builder's calls written into this plan:**
  - Format support is decided **per file**: an unsupported double-click opens the default app. Nothing is remembered per extension, so one corrupt `.zip` can't disable zip browsing for the session.
  - Browse Contents uses a fixed container list.
  - Archive passwords live in memory for the session.
  - The undo title for extraction is "Extract".
  - Nested archives (an archive inside an archive) open in the default app through the temporary cache.
