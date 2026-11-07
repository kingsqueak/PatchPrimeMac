#!/bin/bash
# Builds PatchPrimeEngine.app into build/. Signs with this Mac's development
# certificate if it has one, so microphone permission survives rebuilds.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build -c release --product PatchPrimeEngine
swift build -c release --product patchprime-ctl
bin="$(swift build -c release --show-bin-path)"
app="$root/build/PatchPrimeEngine.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp packaging/PatchPrimeEngine-Info.plist "$app/Contents/Info.plist"
cp "$bin/PatchPrimeEngine" "$app/Contents/MacOS/PatchPrimeEngine"
cp "$bin/patchprime-ctl" "$root/build/patchprime-ctl"
id="$(security find-identity -v -p codesigning | sed -n 's/.*\([0-9A-F]\{40\}\).*/\1/p' | head -1)"
codesign --force --sign "${id:--}" "$app"
codesign -dv "$app" 2>&1 | grep -E '^(Authority|Signature)=' | head -1
