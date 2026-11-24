#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
OPEN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c) CONFIG="$2"; shift 2 ;;
        --open) OPEN=1; shift ;;
        *) echo "usage: $0 [-c debug|release] [--open]" >&2; exit 2 ;;
    esac
done

swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

APP=build/MacCommander.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/MacCommander" "$APP/Contents/MacOS/MacCommander"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f THIRD-PARTY-NOTICES.md ]]; then
    echo "error: THIRD-PARTY-NOTICES.md is missing; it must ship in the app bundle" >&2
    exit 1
fi
cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Core's strings tables. L10n looks for this bundle in Contents/Resources and falls back to English without it.
CORE_BUNDLE="$BIN_PATH/MacCommander_MacCommanderCore.bundle"
if [[ ! -d "$CORE_BUNDLE" ]]; then
    echo "error: $CORE_BUNDLE is missing; the app would show English only" >&2
    exit 1
fi
cp -R "$CORE_BUNDLE" "$APP/Contents/Resources/"
# The translated privacy prompts. These .lproj folders also tell macOS which languages the app has, which
# decides the language of the Core bundle's tables and of AppKit's own menu items.
cp -R Resources/*.lproj "$APP/Contents/Resources/"

if [[ -n "${MC_SIGN_IDENTITY:-}" ]]; then
    SIGN=(--force --options runtime --timestamp --sign "$MC_SIGN_IDENTITY")
else
    SIGN=(--force --options runtime --sign -)
fi
# Inside out: the Core bundle comes with the build's ad-hoc signature, which the app's own identity replaces.
codesign "${SIGN[@]}" "$APP/Contents/Resources/MacCommander_MacCommanderCore.bundle"
codesign "${SIGN[@]}" "$APP"

if [[ -n "${MC_NOTARY_PROFILE:-}" && "$CONFIG" == "release" ]]; then
    ditto -c -k --keepParent "$APP" build/MacCommander.zip
    xcrun notarytool submit build/MacCommander.zip --keychain-profile "$MC_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

if [[ $OPEN -eq 1 ]]; then
    open "$APP"
fi
