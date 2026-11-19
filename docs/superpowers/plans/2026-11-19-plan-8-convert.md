# MacCommander Plan 8: Convert Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Right-click → Convert ▸ for images, audio, video, documents, archives and BIN/CUE, writing the result next to the original with progress, Cancel and Undo.

**Architecture:**
- **Core** gets a pure **catalog**, which decides which targets apply to a selection, and the **tool commands**, the exact arguments for sips, afconvert, avconvert, textutil, bsdtar and ffmpeg.
- **Core** also gets an in-process **CUE parser and ISO writer**, an **ffmpeg locator**, a **PDF renderer**, and a single-file **`Converter`**. The Converter writes into a hidden `.mc-partial-` folder and moves the result into place without overwriting.
- On top of these, **`FileOperationCenter.convert`** runs a batch as one operation (progress, Cancel, Undo).
- `ProcessRunner` gains streaming output lines for video progress.
- The **UI** adds the Convert submenu, the ISO audio-track confirmation, the archive password prompt and the result alert.

**Tech Stack:** Swift 6, SwiftPM (Command Line Tools only), AppKit/SwiftUI, Foundation `Process`, PDFKit (tests), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-19-convert-design.md` (builds on `docs/superpowers/specs/2026-11-17-maccommander-design.md`).

## Global Constraints

- Swift 6, macOS 15 minimum, Command Line Tools only. Run tests with `scripts/test.sh` and build the app with `scripts/build-app.sh`. The `@State` and `@Entry` macros are unavailable in views.
- Tools, by absolute path:
  - `/usr/bin/sips`
  - `/usr/bin/afconvert`
  - `/usr/bin/avconvert`
  - `/usr/bin/textutil`
  - `/usr/bin/bsdtar`
  - ffmpeg only at `/opt/homebrew/bin/ffmpeg`, then `/usr/local/bin/ffmpeg`. Never `PATH`, never bundled.
- Quality values (verbatim from the spec):
  - JPEG 85 %
  - M4A AAC 256 kbit/s
  - WAV/AIFF 16-bit PCM at the source rate
  - MP3 `libmp3lame` 192 kbit/s
  - FLAC at ffmpeg's default level
  - "MP4 (H.264)" = `PresetHighestQuality` to `.mp4`, "MOV (HEVC)" = `PresetHEVCHighestQuality`
  - ffmpeg MP4: remux first (`-c copy`, first video track + all audio), else re-encode `h264_videotoolbox` + AAC; subtitles dropped
  - PDF: system default paper size, 2 cm margins
- **Never overwrite, never touch originals.** Outputs are written inside a hidden `.mc-partial-<UUID>` folder in the destination folder, under their final file name, then moved into place with `FileTransfer.exclusiveRename`. On `EEXIST`, `NameGenerator.keepBothName` gives the next name. The temporary folder is removed on every exit path.
- **Threads:**
  - Process-based conversions run on the operation's own thread (`FileOperationCenter.run`).
  - The PDF renderer runs on the main actor.
  - Nothing blocks the main thread on file-system calls.
- Tests never require ffmpeg (inject the locator or runner) and never touch the real Trash.
- Strings use `String(localized:)`. Menu texts are verbatim:
  - "Convert"
  - "More formats need ffmpeg (brew install ffmpeg)"
  - "ffmpeg is installed but doesn't start (brew reinstall ffmpeg)"
  - The ISO confirmation: "“<name>” has <n> audio tracks. An ISO can only hold the data track; the audio tracks will be left out.", buttons "Convert" / "Cancel".
- Git: work on `main` with no worktrees, and commit per task. Commit messages end with the `Co-Authored-By` trailer.

## Rulings made while planning (what — why — cost if wrong)

- **P8-1** The temporary folder uses the existing `.mc-partial-` prefix, not the spec's `.maccommander-convert-`. — Every other staging folder in the app uses it, and the existing cleanup and hide rules know it. — Cost: none.
- **P8-2** Target labels: "JPEG Image", "PNG Image", "HEIC Image", "TIFF Image", "M4A Audio (AAC)", "WAV Audio", "AIFF Audio", "MP3 Audio", "FLAC Audio", "MP4 Video (H.264)", "MOV Video (HEVC)", "MP4 Video", "Word Document (DOCX)", "Rich Text (RTF)", "Plain Text (TXT)", "Web Page (HTML)", "PDF (simple layout)", "ZIP Archive", "TAR.GZ Archive", "7-Zip Archive", "Disc Image (ISO)". — The spec leaves wording to the builder. — Cost: cosmetic.
- **P8-3** ffmpeg remux failure is detected by a non-zero exit status, then the re-encode runs. — Simplest, and needs no ffprobe. — Cost: a remux that "succeeds" with an unplayable codec in MP4 (rare: VP9 or Opus in MP4 is valid) is kept.
- **P8-4** Audio targets for an ffmpeg-only source don't exist in the table today, so audio always gets afconvert targets plus the ffmpeg extras.

## Review Focus

1. **A converted file whose name already exists next to it** must never replace it ("IMG 2.jpg"). Pinned by `ConverterTests.neverOverwritesExistingOutput`.
2. **Cancel during a long video conversion** must leave no half file and no `.mc-partial-` folder. Pinned by `ConverterTests.cancelLeavesNothingBehind` (with a slow fake tool).
3. **A selection mixing types** (an image and a video) shows no Convert item, and txt + docx shows only shared targets. Pinned by `ConvertCatalogTests.mixedSelectionIntersects`.
4. **A CUE with audio tracks or several BIN files** must be refused or confirmed, never produce a broken ISO. Pinned by `CueSheetTests.*` and `DiscImageWriterTests.refusesMultiFileDataTrack`.
5. **A batch where one file fails** still converts the rest and reports the failure by name; undo covers only the produced files. Pinned by `ConvertOperationTests.partialFailureKeepsOthersAndUndoesOnlyOutputs`.

---

### Task 1: Convert catalog

**Files:**
- Create: `Sources/MacCommanderCore/Convert/ConvertTarget.swift`, `Sources/MacCommanderCore/Convert/ConvertCatalog.swift`
- Test: `Tests/MacCommanderCoreTests/ConvertCatalogTests.swift`

**Interfaces:**
- Produces:

```swift
public enum ConvertTarget: String, CaseIterable, Sendable, Hashable {
    case jpeg, png, heic, tiff, m4a, wav, aiff, mp3, flac, mp4H264, movHEVC, mp4FFmpeg,
         docx, rtf, txt, html, pdf, zip, tarGz, sevenZip, iso
    public var label: String            // Ruling P8-2, String(localized:)
    public var fileExtension: String    // "jpg","png","heic","tiff","m4a","wav","aiff","mp3","flac","mp4","mov","mp4","docx","rtf","txt","html","pdf","zip","tar.gz","7z","iso"
    public var needsFFmpeg: Bool        // mp3, flac, mp4FFmpeg
}
public enum ConvertKind: Sendable, Equatable { case image, audio, videoNative, videoFFmpeg, document, archive, discImage }
public enum FFmpegStatus: Sendable, Equatable { case missing, broken, available(URL) }
public struct ConvertMenu: Equatable, Sendable {
    public let targets: [ConvertTarget]   // in ConvertTarget.allCases order
    public let ffmpegHint: String?        // the verbatim hint line, or nil
}
public enum ConvertCatalog {
    /// Extension (lowercased, compound "tar.gz"/"tar.bz2"/"tar.xz" recognised) → kind; nil = not convertible.
    public static func kind(of url: URL, cueExists: (URL) -> Bool) -> ConvertKind?
    /// Normalized format key: jpeg→jpg, tif→tiff, htm→html, tgz→tar.gz, aif→aiff.
    public static func formatKey(of url: URL) -> String
    /// Targets valid for every URL (intersection by kind table, minus each file's own format),
    /// ffmpeg targets only when `.available`; hint only when ffmpeg would add a target and isn't available.
    public static func menu(for urls: [URL], ffmpeg: FFmpegStatus, cueExists: (URL) -> Bool) -> ConvertMenu
    /// The files a command converts: a `.bin` whose `.cue` is also in `urls` is dropped; a lone `.bin` maps to its `.cue`.
    public static func sources(for urls: [URL], cueExists: (URL) -> Bool) -> [URL]
}
```

Kind table (spec §2.2):
- **image:** heic, heif, jpg, jpeg, png, tif, tiff, gif, bmp, webp, avif → jpeg, png, heic, tiff
- **audio:** wav, aif, aiff, m4a, mp3, caf, flac, aac → m4a, wav, aiff + (ffmpeg) mp3, flac
- **videoNative:** mov, mp4, m4v → mp4H264, movHEVC
- **videoFFmpeg:** mkv, avi, webm, wmv, flv → (ffmpeg) mp4FFmpeg
- **document:** docx, doc, rtf, odt, html, htm, txt → docx, rtf, txt, html, pdf
- **archive:** zip, tar, tgz, tar.gz, tbz, tar.bz2, txz, tar.xz, 7z, rar → zip, tarGz, sevenZip
- **discImage:** cue, or a bin with a same-named cue → iso

"Own format" exclusion compares `formatKey` with the target's `fileExtension` under the same aliases, so mp4 → mp4H264 and mov → movHEVC drop out automatically, while mov → mp4H264 and mp4 → movHEVC stay.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func heicOffersImageTargetsExceptOwn()      // [a.heic] → [.jpeg, .png, .tiff]; hint nil
@Test func jpegAliasExcludesJPEG()                // [a.JPEG] → [.png, .heic, .tiff]
@Test func audioWithoutFFmpegShowsHint()          // [a.wav], .missing → [.m4a, .aiff], hint "More formats need ffmpeg (brew install ffmpeg)"
@Test func audioWithBrokenFFmpegShowsReinstall()  // .broken → hint "ffmpeg is installed but doesn't start (brew reinstall ffmpeg)"
@Test func audioWithFFmpegAddsMP3FLAC()           // [a.wav], .available → [.m4a, .aiff, .mp3, .flac], hint nil
@Test func mkvNeedsFFmpeg()                       // [a.mkv], .missing → [], hint set; .available → [.mp4FFmpeg]
@Test func nativeVideoExcludesSameContainer()     // [a.mp4] → [.movHEVC]; [a.mov] → [.mp4H264]
@Test func mixedSelectionIntersects()             // [a.png, b.mov] → [] hint nil; [a.txt, b.docx] → [.docx, .rtf, .txt, .html, .pdf]
@Test func archivesTgzEqualsTarGz()               // [a.tgz] → [.zip, .sevenZip]; [a.tar.gz] same; [a.rar] → [.zip, .tarGz, .sevenZip]
@Test func binNeedsCue()                          // [g.bin] with cueExists false → []; true → [.iso]; [g.cue] → [.iso]
@Test func binAndCueBecomeOneSource()             // sources([g.bin, g.cue]) == [g.cue]; sources([g.bin]) == [g.cue]
@Test func unknownExtensionNoMenu()               // [a.xyz], [folder/] → []
```

- [ ] **Step 2: Run** `scripts/test.sh --filter ConvertCatalogTests`. Expect a compile failure.
- [ ] **Step 3: Implement** both files as specified.
- [ ] **Step 4: Run** the filter, then `scripts/test.sh`. All tests pass.
- [ ] **Step 5: Commit** `feat: convert catalog (targets per selection)`.

---

### Task 2: Streaming process output

**Files:**
- Modify: `Sources/MacCommanderCore/System/ProcessRunner.swift`
- Test: `Tests/MacCommanderCoreTests/ProcessRunnerTests.swift`

**Interfaces:**
- Produces: `ProcessRunner.run(_:_:currentDirectory:onLine:)`, where `onLine: (@Sendable (String) -> Void)? = nil` gets every stdout and stderr line, split on `\n` **and** `\r` (avconvert and ffmpeg use `\r`), without the terminator. Empty lines are skipped. `ProcessOutput` is unchanged: stdout and stderr are still collected in full. Existing callers compile unchanged.

- [ ] **Step 1: Write the failing test** `streamsLinesSplitOnCRAndLF`. Run `/bin/sh -c "printf 'a\rb\nc' ; printf 'x\n' >&2"`. Collect the lines in a `Mutex<[String]>`. Expect the set {"a","b","c","x"}, and `output.status == 0`.
- [ ] **Step 2: Run** `scripts/test.sh --filter ProcessRunnerTests`. Expect a failure.
- [ ] **Step 3: Implement.** Split incrementally in the existing pipe drain. A partial line is carried over, and the remainder is flushed at EOF.
- [ ] **Step 4: Run** the filter, then the full suite. All tests pass.
- [ ] **Step 5: Commit** `feat: ProcessRunner streams output lines`.

---

### Task 3: CUE sheet and ISO writer

**Files:**
- Create: `Sources/MacCommanderCore/Convert/CueSheet.swift`, `Sources/MacCommanderCore/Convert/DiscImageWriter.swift`
- Test: `Tests/MacCommanderCoreTests/CueSheetTests.swift`, `Tests/MacCommanderCoreTests/DiscImageWriterTests.swift`

**Interfaces:**
- Produces:

```swift
public struct CueSheet: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case mode1_2048, mode1_2352, mode2_2336, mode2_2352, audio }
    public struct Track: Equatable, Sendable {
        public let number: Int; public let mode: Mode; public let file: String
        public let index01Frames: Int          // mm*60*75 + ss*75 + ff
        public let nextStartFrames: Int?       // next track's INDEX 00 (else 01) in the same file; nil = to end
    }
    public let tracks: [Track]
    public var audioTrackCount: Int { get }
    public static func parse(_ text: String) throws(DiscImageError) -> CueSheet
}
public enum DiscImageError: Error, Equatable, Sendable {
    case noDataTrack, multipleDataFiles, missingBin(String), sizeMismatch, unreadable(String)
}
public enum DiscImageWriter {
    /// Resolves the data track's BIN next to `cue` (exact name, then case-insensitive), writes the ISO to
    /// `output` (must not exist). Returns the number of MODE2 Form 2 sectors written as zeros.
    /// Checks `Task.isCancelled` between 1 MB chunks (throws CancellationError); `progress(0...1)`.
    @concurrent public static func writeISO(cue: URL, to output: URL,
        progress: @escaping @Sendable (Double) -> Void) async throws -> Int
}
```

Sector rules (spec §2.4 and §2.6): 2048 bytes per sector, taken from these offsets:

| Mode | Sector size | Data offset |
|---|---|---|
| MODE1/2048 | 2048 | 0 |
| MODE1/2352 | 2352 | 16 |
| MODE2/2352 | 2352 | 24 |
| MODE2/2336 | 2336 | 8 |

The ISO comes from the first data track, read from INDEX 01 (byte offset `frames × sectorSize`) up to `nextStartFrames` or the end of the file. For MODE2/2352, a sector whose subheader submode byte (offset 18) has bit `0x20` set is Form 2 and is written as 2048 zero bytes; the writer counts these. A track file length that isn't a whole number of sectors throws `sizeMismatch`. When the data track's file differs from another data track's file, the writer throws `multipleDataFiles`.

- [ ] **Step 1: Write the failing tests** (synthetic BINs written with `TemporaryDirectory`; sector payloads filled with a per-sector byte pattern):

```swift
@Test func parsesTracksModesAndIndexes()      // FILE "Game.bin" BINARY / TRACK 01 MODE2/2352 / INDEX 01 00:00:00 / TRACK 02 AUDIO / INDEX 00 00:02:00 / INDEX 01 00:04:00 → 2 tracks, track1.nextStartFrames == 150, audioTrackCount == 1
@Test func rejectsNoDataTrack()               // only AUDIO tracks → throws .noDataTrack
@Test func mode1_2352StripsHeaderAndECC()      // 3 sectors → ISO 6144 bytes == payload bytes [16..<2064] of each
@Test func mode1_2048CopiesVerbatim()
@Test func mode2_2352Form1AndForm2()           // sector 2 has submode 0x20 → zeros, return value 1
@Test func mode2_2336Offset8()
@Test func stopsAtNextTrack()                  // data track then audio in the same BIN → ISO has only the data sectors
@Test func refusesMultiFileDataTrack()         // two MODE1 tracks in different FILEs → .multipleDataFiles
@Test func missingBinNamed()                   // .missingBin("Game.bin")
@Test func caseInsensitiveBinName()            // FILE "GAME.BIN" with game.bin on disk → works
@Test func sizeMismatchRejected()              // BIN of 2352*2+5 bytes → .sizeMismatch
```

- [ ] **Step 2: Run** `scripts/test.sh --filter "CueSheetTests|DiscImageWriterTests"`. Expect a compile failure.
- [ ] **Step 3: Implement.** Read the file with `FileHandle` in chunks of whole sectors. The parser accepts quoted and unquoted `FILE` names and ignores `REM`, `PREGAP`, `FLAGS` and unknown lines.
- [ ] **Step 4: Run** the filter, then the full suite. All tests pass.
- [ ] **Step 5: Commit** `feat: BIN/CUE to ISO writer`.

---

### Task 4: ffmpeg locator

**Files:**
- Create: `Sources/MacCommanderCore/Convert/FFmpegLocator.swift`
- Test: `Tests/MacCommanderCoreTests/FFmpegLocatorTests.swift`

**Interfaces:**
- Produces:

```swift
public actor FFmpegLocator {
    public static let shared: FFmpegLocator      // real paths, real `ffmpeg -version`
    public init(candidates: [URL], isExecutable: @escaping @Sendable (URL) -> Bool,
                versionCheck: @escaping @Sendable (URL) async -> Bool, now: @escaping @Sendable () -> Date = Date.init)
    /// Cached result; re-checks when older than 60 s (or never checked). The first candidate that is
    /// executable decides: version check passes → .available(url), fails → .broken; none executable → .missing.
    public func status() async -> FFmpegStatus
    /// Last known result without checking (nil before the first check) — for building menus synchronously.
    public nonisolated var cachedStatus: FFmpegStatus? { get }
}
```

The real `versionCheck` runs `ffmpeg -version` through `ProcessRunner`. A 5 s timeout terminates it, and the check counts as passed when the exit status is 0.

- [ ] **Step 1: Write the failing tests:** `missingWhenNoCandidate`, `availableUsesFirstExecutable`, `brokenWhenVersionFails`, `cachesFor60Seconds` (a fake clock: two calls within 60 s run one check; after 61 s a second check runs), and `cachedStatusNilBeforeFirstCheck`.
- [ ] **Step 2: Run** `scripts/test.sh --filter FFmpegLocatorTests`. Expect a failure.
- [ ] **Step 3: Implement.** `cachedStatus` is backed by a `Mutex`.
- [ ] **Step 4: Run** the filter, then the full suite. All tests pass.
- [ ] **Step 5: Commit** `feat: ffmpeg locator`.

---

### Task 5: Tool commands and the single-file Converter

**Files:**
- Create: `Sources/MacCommanderCore/Convert/ConvertCommand.swift`, `Sources/MacCommanderCore/Convert/Converter.swift`, `Sources/MacCommanderCore/Convert/DocumentPDFRenderer.swift`
- Test: `Tests/MacCommanderCoreTests/ConvertCommandTests.swift`, `Tests/MacCommanderCoreTests/ConverterTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4. `ArchiveExtractor.stage(_:from:near:password:)` (entries `[""]` = everything) and `removeStaging`, `FileTransfer.exclusiveRename`, `NameGenerator.keepBothName`.
- Produces:

```swift
public struct ToolInvocation: Equatable, Sendable { public let executable: URL; public let arguments: [String] }
public enum ConvertCommand {
    /// Exact invocations for process-based targets (not pdf, iso, archives).
    public static func invocations(source: URL, target: ConvertTarget, output: URL, ffmpeg: URL?) -> [ToolInvocation]
    /// Parses "avconvert progress:  42.50% complete" → 0.425; ffmpeg "out_time_us=…" against `durationMicroseconds`.
    public static func avconvertProgress(_ line: String) -> Double?
    public static func ffmpegProgress(_ line: String, durationMicroseconds: Int64?) -> Double?
    /// "  Duration: 00:01:02.50, start…" → 62_500_000.
    public static func ffmpegDuration(_ line: String) -> Int64?
}
public struct ConvertOutcome: Sendable, Equatable { public let output: URL; public let zeroFilledSectors: Int }
public enum Converter {
    /// Converts one file next to it (spec §2.3, §2.6). `password` is for archives. Never overwrites.
    @concurrent public static func convert(_ source: URL, to target: ConvertTarget, ffmpeg: URL?, password: String?,
        progress: @escaping @Sendable (Double) -> Void) async throws -> ConvertOutcome
}
@MainActor public enum DocumentPDFRenderer {
    /// NSAttributedString (no remote resources) → paginated PDF at the default paper size, 2 cm margins.
    public static func render(_ document: URL, to output: URL) throws
}
```

Exact invocations (tests assert them):

| Target | Command |
|---|---|
| jpeg | `sips -s format jpeg -s formatOptions 85 <src> --out <out>` |
| png / heic / tiff | `sips -s format png\|heic\|tiff <src> --out <out>` |
| m4a | `afconvert -f m4af -d aac -b 256000 <src> <out>` |
| wav | `afconvert -f WAVE -d LEI16 <src> <out>` |
| aiff | `afconvert -f AIFF -d BEI16 <src> <out>` |
| mp3 | `ffmpeg -nostdin -hide_banner -y -i <src> -vn -c:a libmp3lame -b:a 192k -progress pipe:1 <out>` |
| flac | `ffmpeg -nostdin -hide_banner -y -i <src> -vn -c:a flac -progress pipe:1 <out>` |
| mp4H264 | `avconvert --source <src> --preset PresetHighestQuality --output <out> --progress` |
| movHEVC | `avconvert --source <src> --preset PresetHEVCHighestQuality --output <out> --progress` |
| mp4FFmpeg | two invocations, tried in order: (1) `ffmpeg -nostdin -hide_banner -y -i <src> -map 0:v:0 -map 0:a? -c copy -sn -movflags +faststart -progress pipe:1 <out>`, then (2) `… -map 0:v:0 -map 0:a? -c:v h264_videotoolbox -b:v 8M -c:a aac -b:a 192k -sn -movflags +faststart -progress pipe:1 <out>` |
| docx / rtf / txt / html | `textutil -convert docx\|rtf\|txt\|html <src> -output <out>` |

`-y` is safe because `<out>` is always inside the private temp folder.

Converter flow:
1. Make `<dir>/.mc-partial-<UUID>/`. The output is `<that>/<source stem>.<ext>`; the stem drops a compound archive extension (`a.tar.gz` → `a`).
2. Run the invocations in order. The first one with exit status 0 wins. On failure, the error is `ConvertError.toolFailed(String)`, holding the first non-empty stderr line, or "<tool> failed (status n)".
3. Special targets:
   - pdf: `await MainActor.run { try DocumentPDFRenderer.render(src, to: out) }`
   - iso: `DiscImageWriter.writeISO`
   - zip / tarGz / sevenZip: `ArchiveExtractor.stage([""], from: src, near: tempFolder, password:)`, then `bsdtar -c` in the staging folder with `--format zip` / `-z --format pax` / `--format 7zip` over the staged top-level items, and `removeStaging`.
4. Move into place: `keepBothName` for the final name, then `exclusiveRename`, retrying on `EEXIST` up to 100 times.
5. `defer` removes the temp folder. Cancellation terminates the tool (ProcessRunner) and rethrows `CancellationError`.

`ConvertError: Error, Equatable, LocalizedError` has the cases `toolFailed(String)`, `disc(DiscImageError)` and `archive(ArchiveError)`, each with a readable `errorDescription`.

- [ ] **Step 1: Write the failing tests.**
  - `ConvertCommandTests`: one test per row of the table above, asserting `executable.path` and `arguments` exactly, plus `avconvertProgressParses` ("avconvert progress:  42.50% complete" → 0.425), `ffmpegProgressParses` (`out_time_us=1000000` with duration 2_000_000 → 0.5; `progress=end` → nil) and `ffmpegDurationParses`.
  - `ConverterTests`, using real built-in tools on fixtures created in the test:
    - a PNG drawn with CoreGraphics
    - a text file
    - a WAV with a hand-written 44-byte header and 0.1 s of silence
    - a zip made with `/usr/bin/ditto`
    - a synthetic BIN/CUE

    The tests:

```swift
@Test func pngToJPEG()                          // output a.jpg exists, CGImageSource type == public.jpeg
@Test func txtToRTFAndPDF()                     // a.rtf starts with "{\\rtf"; a.pdf opens in PDFDocument with pageCount >= 1
@Test func wavToM4A()                           // a.m4a exists, size > 0
@Test func zipToTarGzKeepsEntries()             // bsdtar -tf lists the original entries
@Test func cueToISOReportsZeroSectors()         // outcome.zeroFilledSectors == 1 for a Form 2 fixture
@Test func neverOverwritesExistingOutput()      // a.jpg already exists → output "a 2.jpg", original a.jpg untouched (bytes equal)
@Test func failureLeavesNothingBehind()         // corrupt "x.png" (text bytes) → throws .toolFailed, folder has only x.png
@Test func cancelLeavesNothingBehind()          // ffmpeg path pointed at a script `sleep 30`; cancel after 200 ms → CancellationError, no .mc-partial-* left, returns < 2 s
@Test func ffmpegFallsBackToReencode()          // fake ffmpeg script: exits 1 when args contain "-c copy", else writes the output file → success; invocation log shows both
```

    The fake ffmpeg is a shell script written into the test's `TemporaryDirectory` and passed as the `ffmpeg:` URL.

- [ ] **Step 2: Run** `scripts/test.sh --filter "ConvertCommandTests|ConverterTests"`. Expect a compile failure.
- [ ] **Step 3: Implement** the three files.
- [ ] **Step 4: Run** the filter, then the full suite. All tests pass.
- [ ] **Step 5: Commit** `feat: single-file converter`.

---

### Task 6: Convert operation (batch, progress, undo)

**Files:**
- Modify: `Sources/MacCommanderCore/Operations/FileOperationCenter.swift`
- Test: `Tests/MacCommanderCoreTests/ConvertOperationTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 4, 5.
- Produces:

```swift
public struct ConvertFailure: Sendable, Equatable { public let source: URL; public let message: String }
public struct ConvertBatchResult: Sendable, Equatable {
    public let outputs: [URL]; public let failures: [ConvertFailure]
    public let zeroFilledSectors: Int; public let cancelled: Bool
}
extension FileOperationCenter {
    /// Converts `ConvertCatalog.sources(for: items)` one after another in one listed operation titled
    /// "Converting “a.heic”…" / "Converting 3 items…". Progress = (done + current fraction) / count.
    /// `askPassword(archive, incorrect)` is called for an encrypted archive (nil = skip it, recorded as a
    /// failure "cancelled"). Cancel stops the batch (cancelled = true, finished outputs kept).
    /// Undo record `.created(outputs)` titled "Convert" when outputs is non-empty. Posts folders-did-change.
    public func convert(_ items: [URL], to target: ConvertTarget, ffmpeg: URL?,
        askPassword: @escaping @Sendable (URL, Bool) async -> String?) async -> ConvertBatchResult
}
```

Use the existing private `run(kind: "convert", title:)` and progress reporting (`TransferProgress`). For archives, the session password is read from `ArchiveCatalog.shared` first, then `askPassword` is asked; a password that works is stored with `setPassword`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func convertsBatchAndRegistersUndo()     // two PNGs → two JPEGs; undo.undoTitle == "Convert"; undo moves both to a test trash (existing test Trasher pattern) and originals remain
@Test func partialFailureKeepsOthersAndUndoesOnlyOutputs() // good.png + bad.png → outputs [good.jpg], failures [bad.png with non-empty message]
@Test func nothingProducedNoUndo()             // only bad.png → outputs [], undo.undoTitle unchanged
@Test func binAndCueConvertOnce()              // items [g.bin, g.cue] → one ISO
@Test func listedWhileRunningAndRemovedAfter() // operations contains one status during the run, none after
```

(Build the center like `FileOperationCenterTests` does — `FileOperationCenter(undo: FileUndoStack(trash: trash), trash: trash)` with its test trash — so the real Trash is never touched.)

- [ ] **Step 2: Run** `scripts/test.sh --filter ConvertOperationTests`. Expect a compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter, then the full suite. All tests pass.
- [ ] **Step 5: Commit** `feat: convert operation with progress and undo`.

---

### Task 7: Convert menu and dialogs (UI)

**Files:**
- Create: `Sources/MacCommander/Operations/ConvertActions.swift`
- Modify: `Sources/MacCommander/FileList/FileContextMenu.swift`, `Sources/MacCommander/App/MacCommanderApp.swift` (start `FFmpegLocator.shared.status()` once at launch)

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 6; `FileActions.showAlert`, `ArchivePasswordSheet.ask(for:incorrect:window:)`, `model.selectAfterOperation`.
- Produces: `ConvertActions.menuItem(for items: [FileItem], model: BrowserModel, window: NSWindow?) -> NSMenuItem?` (nil = no Convert item), and `ConvertActions.run(_ urls: [URL], to: ConvertTarget, model:, window:) async`.

Steps:
- [ ] **Step 1: Menu.**
  - In `FileContextMenu.forItems`, after the Compress block, add the Convert submenu. It is built from `ConvertCatalog.menu(for:ffmpeg:cueExists:)` with `FFmpegLocator.shared.cachedStatus ?? .missing`; a cue lookup with `FileManager.fileExists` is acceptable here (local metadata, one stat per `.bin`).
  - It is not added for archive entries, folders, or an empty target list without a hint.
  - The hint line is a disabled item at the end, after a separator.
  - Building the menu also triggers `Task { await FFmpegLocator.shared.status() }` to refresh the cache for next time.
- [ ] **Step 2: Run.**
  - For `.iso`, read each CUE off the main thread (`PathQueries.run`) and parse it. When `audioTrackCount > 0`, show the verbatim confirmation as a sheet; Cancel aborts the command.
  - Then `model.operations.convert(...)`, with an `askPassword` that hops to the main actor and calls `ArchivePasswordSheet.ask(for:incorrect:window:)`, and an ffmpeg URL from `FFmpegLocator.shared.status()`.
  - Afterwards, `await model.selectAfterOperation(result.outputs)`.
  - Then one alert, through `FileActions.showAlert`, with one line per failure, "“name” couldn’t be converted: message". When `zeroFilledSectors > 0`, add "<n> unreadable sectors were written as zeros." Nothing shows on full success or after Cancel without failures.
- [ ] **Step 3: Build and test.** `scripts/build-app.sh` reports BUILD OK and `scripts/test.sh` passes everything.
- [ ] **Step 4: Launch check.** Do it only if `pgrep -x MacCommander` finds no running instance. Never quit or launch over the user's instance.
- [ ] **Step 5: Commit** `feat: Convert context menu`.

---

## Manual checks for the user (after all tasks)

- **M1** HEIC → JPG: the result appears next to the original and is selected; converting again gives "IMG 2.jpg"; ⌘Z removes it.
- **M2** MKV → MP4 with ffmpeg: a fast remux, the percentage moves, and the file plays in QuickTime. With ffmpeg temporarily renamed: the menu shows the hint line.
- **M3** WAV → MP3 plays. M4A, AIFF and FLAC also work.
- **M4** DOCX → PDF (simple layout): text and simple tables are present, and the page size is right.
- **M5** BIN/CUE → ISO: it mounts in Finder (double-click). A game with audio tracks shows the confirmation first.
- **M6** Archives: RAR → ZIP; an encrypted 7z asks for its password; Cancel at the prompt skips only that archive.
- **M7** Cancel a long video conversion: no partial file and no hidden folder are left behind.
- **M8** Mixed selection (an image and a video): no Convert item. Inside an archive: no Convert item.
