# Security policy

## Reporting a vulnerability

Write to **security@noix.dev**. Please do not open a public issue for
anything you believe is a security problem — the issue tracker is public
from the moment you press the button.

Include whatever you have: what you did, what happened, and which version
you were running (MacCommander → About MacCommander). A proof of concept
helps, and so does an explanation of what an attacker gains — but a report
you are unsure about is still worth sending. A false alarm costs one reply;
an unreported flaw costs more.

**Do not include credentials.** Not yours, not a file server's. If a
password or a share address of the shape `smb://user:secret@host/Share` is
part of the reproduction, describe its role and leave the value out.

## What is in scope

MacCommander runs without a sandbox, can be given Full Disk Access, signs in
to network shares, and hands files to command-line tools. The interesting
surface follows from that:

- **Stored credentials.** Network share passwords live in the macOS Keychain
  and nowhere else; the share list and the preferences are JSON and never
  contain them. A path that writes a password into a file, a log, an error
  message or a crash report is a bug worth reporting.
- **Archives.** Browsing, extracting and converting archives must never
  write outside the folder you chose — an entry name that escapes it
  (`../`, absolute paths, symlinks pointing out) is in scope.
- **Files handed to other tools.** Converting and archiving run `bsdtar`,
  `sips`, `afconvert`, `avconvert`, `textutil` and, when installed, `ffmpeg`.
  A file name or file content that makes one of them do something other
  than the conversion you asked for is in scope.
- **Markdown preview and document conversion.** The Markdown preview runs
  with scripts off and a content policy, and converting HTML to PDF loads
  nothing from the network. A document that gets a request out, or runs
  code, through either is in scope. Other previews come from Quick Look,
  which is the system's.
- **Requests from other apps.** With "Use MacCommander for “Show in Finder”"
  turned on, other apps can make MacCommander open windows. Anything beyond
  showing the items they name — opening, running or changing them — is in
  scope.

## What is not

- Findings that need an attacker to already have local access to the Mac
  with your account unlocked. The Keychain and the system's privacy
  controls are the boundary there, and they are the system's.
- Behaviour of a file server, or of `ffmpeg` and other tools themselves,
  that MacCommander only passes through.
- Results from automated scanners with no reproduction attached.

## Which versions

The latest release. There are no maintenance branches — development happens
on `main` and releases are tagged from it, so a fix ships in the next
release rather than as a patch to an older one. The current release is on
the [releases page](https://github.com/NoiXdev/mac-commander/releases/latest).

## What happens next

You will get a reply. If the report is a vulnerability, it is fixed and the
release notes say what changed; you will be credited by whatever name you
ask for, or not at all if you prefer. If it turns out not to be one, you get
the reasoning rather than silence.
