# MacCommander

[![CI](https://github.com/NoiXdev/mac-commander/actions/workflows/ci.yml/badge.svg)](https://github.com/NoiXdev/mac-commander/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/NoiXdev/mac-commander?label=release)](https://github.com/NoiXdev/mac-commander/releases/latest)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-555)](#install)
[![License: MIT](https://img.shields.io/github/license/NoiXdev/mac-commander?label=license)](LICENSE)

**A fast, native file manager for the Mac — a Finder alternative with an
optional Total Commander–style dual-pane mode, network shares, archives and
file conversion.**

MacCommander is built for people who move files all day: browse your disks,
iCloud Drive and network shares in one window, copy between two folders side
by side, look inside archives without unpacking them, and convert a photo,
a song or a video from the context menu.

## Features

- **Browser** — sidebar with Favorites, iCloud Drive, Locations, Network and
  Tags; a sortable list with optional checkbox column; Back/Forward, path bar,
  Go to Folder; hidden files on request.
- **Dual-pane mode** (opt-in in Settings) — two folders side by side with
  Total Commander keys: F5 copy, F6 move, F7 new folder, F8 delete, Tab to
  switch panes, ⌘1/⌘2, Swap Panes, Same Folder in Other Pane. Drag and drop
  and the context menu work between panes too.
- **Network shares** — SMB, NFS and AFP shares in the sidebar with their
  live status, automatic reconnect, and sign-in whose passwords live only in
  the macOS Keychain.
- **File operations** — copy, move, duplicate, rename, trash with undo; a
  strip at the bottom shows running operations with progress and Cancel;
  conflicts ask Keep Both / Replace / Skip.
- **Archives** — browse zip, tar, 7z, rar and more like folders, preview and
  open single entries, extract all, or compress a selection.
- **Convert** — right-click ▸ Convert: images (JPEG, PNG, HEIC, TIFF), audio
  (M4A, WAV, AIFF), video (MP4, MOV), documents (DOCX, RTF, TXT, HTML, PDF)
  and archives (ZIP, TAR.GZ, 7z), plus BIN/CUE → ISO. With
  [ffmpeg](https://formulae.brew.sh/formula/ffmpeg) installed via Homebrew
  also MP3, FLAC and MKV/AVI/WebM → MP4. Results land next to the original,
  never overwrite anything, and ⌘Z removes them.
- **Preview** — a preview pane with Quick Look and a live Markdown preview.
- **Search and tags** — Spotlight-backed search with name patterns, and
  Finder tags in the sidebar and context menu.
- **Open in Terminal** — in Terminal or iTerm, your choice in Settings.
- **Replace “Show in Finder”** — optionally, other apps' “Show in Finder”
  opens MacCommander instead, and folders dropped on its Dock icon open in it.
- **Global hotkey** — bring MacCommander to the front from anywhere.

## Known limitations

- **Folders opened elsewhere still open in the Finder.** macOS doesn't let
  another app become the default for folders, so Spotlight, `open <folder>`
  and Dock stacks keep using the Finder. Other apps' “Show in Finder” and
  folders dropped on MacCommander's Dock icon do reach MacCommander.
- **Open and Save dialogs, the desktop and the Trash** belong to the system
  and stay the Finder's.
- **Apple silicon only.** Release builds are not universal.

## Install

1. Download the latest DMG from the [releases page](https://github.com/NoiXdev/mac-commander/releases).
2. Open it and drag **MacCommander** into **Applications**.
3. Requires macOS 15 or newer. The app is signed and notarized.

For full access to protected folders (Mail, Messages, other users' data),
give MacCommander Full Disk Access when it asks — it works without it, too.

What changed in each release is listed in [CHANGELOG.md](CHANGELOG.md),
generated from the commits that went into it.

## Building from source

MacCommander is a Swift package — no Xcode project. Swift 6 and the Command
Line Tools are enough.

```sh
scripts/test.sh                 # runs the test suite
scripts/build-app.sh --open     # builds build/MacCommander.app and opens it
scripts/build-app.sh -c release # release build
```

`scripts/build-app.sh` signs ad-hoc unless `MC_SIGN_IDENTITY` names a signing
identity, and notarizes a release build when `MC_NOTARY_PROFILE` names a
`notarytool` keychain profile. The Keychain tests run only with
`MC_KEYCHAIN_TESTS=1`, because they write to your real Keychain.

## Reporting something

Bugs and requests go through [the issue forms](https://github.com/NoiXdev/mac-commander/issues/new/choose).
Please leave passwords and share addresses with credentials out of them.

If you think you have found a security problem, do not open an issue —
write to **security@noix.dev**. [SECURITY.md](SECURITY.md) says what is in
scope and what to include.

## Community & Support

Questions, ideas, or running into something? Join the NoiXdev Discord — the
fastest way to get help and talk to us and other users.

[![Join our Discord](https://img.shields.io/badge/Discord-Join%20the%20server-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/sHcvJfXhq)

## License

[MIT](LICENSE) — © 2026 noix.

Third-party dependency licences are listed, with their full text, in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
