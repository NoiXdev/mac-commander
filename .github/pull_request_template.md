<!--
Short is fine. The four headings below are what a reviewer needs; everything
else you want to say is welcome underneath them.
-->

## What this changes

<!-- One or two sentences. What behaviour is different after this than before? -->

## Why

<!--
The situation that made it necessary. If it fixes a reported problem, link the
issue. If you measured something, put the number here rather than "it was
slow" — a number is checkable and an adjective is not.
-->

## How it was verified

<!--
Not "tests pass" — which command, and what it printed. The suite is:

    scripts/test.sh

It runs `swift test` and passes any arguments through (e.g.
`scripts/test.sh --filter BrowserModelTests`). With only the Command Line
Tools installed it adds the Swift Testing plugin path that `swift test`
otherwise cannot find; with Xcode it is plain `swift test`, which is what
CI runs.

Two timing tests are known to be flaky and can fail on a slow or busy
machine without anything being broken:
`BrowserModelTests.operationInCurrentFolderReloads` and
`BrowserModelTests.changesDuringSlowLoadCoalesceIntoOneFollowUp`. Re-run
before you chase them, and say in the PR if you saw one fail.

The Keychain tests do not run by default and are not required for most
changes: `MC_KEYCHAIN_TESTS=1 scripts/test.sh` writes to your real
Keychain. CI never sets it.

For anything you can only see in the running app, build the bundle with
`scripts/build-app.sh --open` and say what you clicked.

If a change cannot be covered by a test, say so and say why — that is a
finding, not an omission.
-->

## Checklist

- [ ] New behaviour comes with a test, and I saw that test fail before the change.
- [ ] `scripts/test.sh` is green, and the build adds no new compiler warnings (CI counts them against a budget).
- [ ] Tests never touch the real Trash, the real Keychain (outside `MC_KEYCHAIN_TESTS=1`) or files outside a temporary directory.
- [ ] No password, real share address, user name or personal file path appears in the diff — including in test fixtures and in expectation messages, which are printed when a test fails.
- [ ] User-visible strings go through `String(localized:)` rather than being written into the code as plain literals.
- [ ] A new or bumped dependency is reflected in `THIRD-PARTY-NOTICES.md` (CI checks every pin in `Package.resolved` against it).
- [ ] Commits follow [Conventional Commits](https://www.conventionalcommits.org/) — the changelog is generated from them.
- [ ] Anything a user would notice is described in this PR in words a user would understand.
