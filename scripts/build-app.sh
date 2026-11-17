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

if [[ -n "${MC_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$MC_SIGN_IDENTITY" "$APP"
else
    codesign --force --options runtime --sign - "$APP"
fi

if [[ -n "${MC_NOTARY_PROFILE:-}" && "$CONFIG" == "release" ]]; then
    ditto -c -k --keepParent "$APP" build/MacCommander.zip
    xcrun notarytool submit build/MacCommander.zip --keychain-profile "$MC_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

if [[ $OPEN -eq 1 ]]; then
    open "$APP"
fi
