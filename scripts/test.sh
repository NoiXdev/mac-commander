#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
    swift test "$@"
else
    swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" "$@"
fi
