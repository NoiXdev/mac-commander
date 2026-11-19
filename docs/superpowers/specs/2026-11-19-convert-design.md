# MacCommander — Convert Files (Design)

Date: 2026-11-19
Status: Draft for approval
Builds on: `2026-11-17-maccommander-design.md` (v1). That spec's non-goal "creating formats other than zip" is lifted for this feature only: archives can be re-packed into the formats below.

## 1. Intent

The user wants to convert files from the context menu instead of opening another app. The conversions they named as everyday ones are:
- HEIC → JPG
- MKV → MP4
- WAV → MP3
- DOCX → PDF
- BIN/CUE → ISO

Around these, the menu also covers the common formats of each file type, as far as macOS's own tools (plus an installed ffmpeg) can produce them.

Success: right-click → Convert ▸ format → the new file appears next to the original, with progress, Cancel and Undo like every other file operation.

## 2. Goals

### 2.1 Menu
- Right-clicking items shows **Convert ▸**. The submenu lists only the target formats that apply to **every** selected file. For example, selecting three HEIC photos shows the image formats.
  - If the selected files have no common target (an image and a video, say), Convert is not shown.
  - Formats equal to the source format are not offered (no "JPEG" for a `.jpg`).
- Convert is not shown inside archives (entries have no real path), for folders, or while a pane shows the Disconnected placeholder.
- Without a working ffmpeg, the submenu ends with one disabled line explaining why the extra formats are missing:
  - **"More formats need ffmpeg (brew install ffmpeg)"** when no ffmpeg is found.
  - **"ffmpeg is installed but doesn't start (brew reinstall ffmpeg)"** when one is found but `ffmpeg -version` fails.

  This line appears only for selections where ffmpeg would add something (audio, video).

### 2.2 Formats

| Source (by extension) | Built-in targets | Extra targets with ffmpeg | Tool |
|---|---|---|---|
| Images: heic, heif, jpg/jpeg, png, tif/tiff, gif, bmp, webp, avif | JPEG, PNG, HEIC, TIFF | — | `sips` |
| Audio: wav, aif/aiff, m4a, mp3, caf, flac, aac | M4A (AAC), WAV, AIFF | **MP3**, FLAC | `afconvert` / ffmpeg |
| Video readable by macOS: mov, mp4, m4v | MP4 (H.264), MOV (HEVC) | — | `avconvert` |
| Video not readable by macOS: mkv, avi, webm, wmv, flv | — | **MP4** | ffmpeg |
| Documents: docx, doc, rtf, odt, html/htm, txt | DOCX, RTF, TXT, HTML, PDF (simple layout) | — | `textutil`; PDF in-process |
| Archives: zip, tar, tgz/tar.gz, tbz/tar.bz2, txz/tar.xz, 7z, rar | ZIP, TAR.GZ, 7Z | — | `bsdtar` |
| Disc images: cue (or a bin with a same-named cue beside it) | ISO | — | in-process |

Details:
- **JPEG** is written at quality 85 %. HEIC uses sips' default quality. Image metadata (EXIF, orientation) is kept wherever sips keeps it.
- **Audio:**
  - M4A is AAC at 256 kbit/s.
  - WAV and AIFF are 16-bit PCM at the source sample rate.
  - MP3 is LAME at 192 kbit/s (`libmp3lame`).
  - FLAC uses ffmpeg's default compression level.
  - For sources macOS can't read (none in the table today), only the ffmpeg targets are offered.
- **Video:**
  - Built-in conversions use `avconvert` presets: "MP4 (H.264)" is `PresetHighestQuality` written as `.mp4`, and "MOV (HEVC)" is `PresetHEVCHighestQuality`. Both keep the resolution.
  - ffmpeg MP4: first try a **remux** without re-encoding (`-c copy`), keeping the first video track and all audio tracks. If that fails, **re-encode** to H.264 (`h264_videotoolbox`) with AAC audio at the source resolution. Subtitles are dropped.
- **Documents:**
  - Text formats go through `textutil -convert`.
  - "PDF (simple layout)" loads the document with macOS's text system (`NSAttributedString`) and prints it, paginated, to PDF at the system's default paper size. Text, fonts, simple tables and inline images are kept. Complex layout (floating images, headers and footers, columns) is not, and the menu label says so.
- **Archives:**
  - The whole archive is extracted to a hidden temporary folder next to it, using the same staging and password handling as v1's "Extract All", then packed with `bsdtar` (`--format zip`, `-z` for tar.gz, `--format 7zip`).
  - An encrypted source asks for its password as when extracting. The output is not encrypted.
- **BIN/CUE → ISO:** see §2.4.

### 2.3 Behavior of a conversion
- **Output location:** next to the source, named after it with the new extension: `IMG_0042.heic` → `IMG_0042.jpg`, `backup.tar.gz` → `backup.zip`, `game.cue` → `game.iso`.
- **No overwriting, ever.** If the name is taken, the existing "Keep Both" naming is used (`IMG_0042 2.jpg`). Originals are never changed or removed.
- **Writing is atomic.** Each output is written to a hidden temporary name in the same folder and renamed into place only on success. Cancel or a failure leaves nothing behind.
- **One operation per command,** shown in the operations strip as "Converting 3 items…".
  - Files are converted one at a time, and progress counts finished files.
  - Cancel stops the running tool (the process is terminated) and skips the rest. Already finished outputs stay.
  - The work runs on the operation's own thread (`FileOperationCenter.run`), so a slow network share never blocks the UI.
- **Undo:** ⌘Z ("Undo Convert") moves the outputs of the last conversion to the Trash, using the existing `.created` undo record.
- **Errors:** a file that fails doesn't stop the others. At the end, one alert lists the failed files with the tool's message (first line of stderr, or the app's own message).
- **After finishing:** the outputs are selected in the pane, as after Duplicate (`selectAfterOperation`).
- **Dual-pane:** outputs go next to the source, never into the other pane.

### 2.4 BIN/CUE → ISO (in-process)
- Parse the CUE sheet: `FILE "<name>" BINARY`, `TRACK nn MODE1/2048 | MODE1/2352 | MODE2/2336 | MODE2/2352 | AUDIO`, and `INDEX 01 mm:ss:ff`. Lines that aren't needed are ignored.
- The ISO is made from the **first data track**:
  - `MODE1/2048`: copy as is.
  - `MODE1/2352`: take 2048 bytes at offset 16 of each 2352-byte sector.
  - `MODE2/2352` (Form 1, as on PlayStation and Video CDs): 2048 bytes at offset 24.
  - `MODE2/2336`: 2048 bytes at offset 8.
- Audio tracks can't go into an ISO. If the CUE contains audio tracks, a confirmation asks first: "“game.cue” has 12 audio tracks. An ISO can only hold the data track; the audio tracks will be left out." Buttons: Convert / Cancel.
- Refused with a clear message:
  - a CUE that references several BIN files for the data track, or a missing BIN;
  - a disc with no data track;
  - a `.bin` without a matching `.cue` (Convert isn't offered then);
  - a BIN whose size doesn't fit the sector size.
- Exporting the audio tracks as WAV is a **non-goal** for now.

### 2.5 Finding ffmpeg
- Look for `ffmpeg` at `/opt/homebrew/bin/ffmpeg` and `/usr/local/bin/ffmpeg`, in that order.
- It counts as **working** when `ffmpeg -version` exits 0 within 5 s.
- The check runs off the main thread once per app launch, and again when a Convert menu is built and more than 60 s have passed since the last check. That way a `brew install` takes effect without relaunching.
- The menu is built from the cached result and never waits for the check.

### 2.6 Settled details *(builder's calls, from the design review)*
- **Temp files:** each output is written inside a hidden temporary folder (`.maccommander-convert-<uuid>`) in the destination folder, under its final file name, so every tool sees the real extension. On success it is moved into place with a **no-clobber** rename. The Keep Both name is chosen at that moment; if the name was taken meanwhile, the next free number is used. The temporary folder is removed afterwards, also on cancel or failure.
- **Progress:** for video (avconvert and ffmpeg), the strip shows a percentage of the current file, parsed from the tool's progress output. This needs streaming output from `ProcessRunner`, an additive API. For everything else, progress counts finished files.
- **Undo:** the undo record lists only the outputs actually produced, including after Cancel. If nothing was produced, there is no undo record and only the error alert is shown.
- **"Same format" rule:** a target is hidden when its extension equals the source's, treating aliases as equal: jpg = jpeg, tif = tiff, htm = html, tgz = tar.gz, aif = aiff. Re-encoding within the same container (mp4 → MP4 (H.264)) is therefore not offered. mov → MP4 and mp4 → MOV (HEVC) are offered.
- **Mixed selections:** the offered targets are the intersection over all selected files, by extension only. txt and docx share DOCX, RTF, HTML, TXT and PDF; each file skips a target equal to its own format. Symlinks are converted by their target's extension; the output goes next to the link.
- **ISO details:**
  - When a `.bin` and its `.cue` are both selected, only one ISO is made.
  - `FILE` names are resolved relative to the CUE's folder. An exact match is tried first, then a case-insensitive one.
  - The data track is read from its `INDEX 01` position (pregap skipped), up to the next track's `INDEX 00`/`INDEX 01`, or to the end of the BIN.
  - MODE2/2352 sectors that are Form 2 (subheader submode bit 5) are written as zero-filled 2048-byte sectors, and the alert mentions how many there were.
- **PDF (simple layout):**
  - Paper is the system default `NSPrintInfo` paper size, with 2 cm margins.
  - The `NSAttributedString` loading and the printing run on the **main actor**. WebKit-based HTML import requires that; the loading is short and done per file. The process-based steps still run off the main thread.
  - Remote resources in HTML are not fetched.
  - A password-protected or unreadable document fails with the loader's message.
  - Cancel takes effect between files.
- **ffmpeg location:** only the two Homebrew paths. MacPorts, Nix and `PATH` are out for now. The hint line is decided per selection, as §2.1 says.
- **Archive passwords in a batch:** the prompt appears as a sheet on the window, one encrypted archive at a time, using v1's prompt. Cancel at the prompt skips that archive, reports it as "cancelled" in the final alert, and the batch continues.

## 3. Non-goals
- Quality, bitrate or size settings, and resizing.
- Batch presets and watch folders.
- Converting into the other pane, or choosing a destination folder.
- Using Microsoft Word, LibreOffice, Pages or other apps for documents.
- Bundling ffmpeg or any other binary.
- Spreadsheets and presentations (xlsx, pptx, numbers, key).
- PDF as a source (PDF → images or text).
- Audio-track export from BIN/CUE, CCD/IMG/MDF and other disc formats, and RAR as a target.
- Subtitles and chapters when converting video.

## 4. Constraints
- All v1 constraints apply: Swift 6, SwiftPM with Command Line Tools only, tests via `scripts/test.sh`, work on `main`, no sandbox.
- Distribution stays signed and notarized without bundled third-party binaries.
- Tests never depend on ffmpeg being installed. ffmpeg paths are tested through an injectable runner or locator; real-tool tests are limited to the built-in tools.
- Tests must not touch the real Trash.

## 5. Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | **Command-line tools** (`sips`, `afconvert`, `avconvert`, `textutil`, `bsdtar`, ffmpeg) run through the existing `ProcessRunner`. In-process code only where no tool exists (PDF, BIN/CUE). | Same pattern as v1's bsdtar use. Cancel terminates the process, and a crash in a codec can't take the app down. Cost: process start-up per file and parsing tool errors. |
| B | In-process frameworks (ImageIO, AVAssetExportSession, ExtAudioFile) | No processes, finer progress. Cost: much more code per format, and it still needs ffmpeg for MKV and MP3. Rejected. |
| C | Bundle ffmpeg | Always available. Cost: about 80 MB, GPL obligations for the MP3 encoder, and keeping it updated. Rejected by the user. |

DOCX → PDF through Microsoft Word was rejected by the user.

## 6. Left to the builder
- Code structure, for example a `Converter` registry in Core mapping (source type → targets → job), with each job a small value type.
- Exact `afconvert`, `avconvert` and `ffmpeg` arguments within the stated quality values.
- How the remux-then-re-encode fallback detects that a remux failed (exit status or `ffprobe`).
- Menu ordering and the exact wording of format labels, for example "JPEG Image", "MP3 Audio".
