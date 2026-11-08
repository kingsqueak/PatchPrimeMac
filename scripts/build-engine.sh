#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
# Builds PatchPrimeEngine.app into build/. Signs with this Mac's development
# certificate if it has one, so microphone permission survives rebuilds.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build -c release --product PatchPrimeEngine
swift build -c release --product patchprime-ctl
swift build -c release --product patchprime-scan
bin="$(swift build -c release --show-bin-path)"
app="$root/build/PatchPrimeEngine.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp packaging/PatchPrimeEngine-Info.plist "$app/Contents/Info.plist"
cp "$bin/PatchPrimeEngine" "$app/Contents/MacOS/PatchPrimeEngine"
cp "$bin/patchprime-scan" "$app/Contents/MacOS/patchprime-scan"
mkdir -p "$app/Contents/Resources/Sounds"
cp packaging/sounds/*.wav "$app/Contents/Resources/Sounds/"
cp "$bin/patchprime-ctl" "$root/build/patchprime-ctl"
id="$(security find-identity -v -p codesigning | sed -n 's/.*\([0-9A-F]\{40\}\).*/\1/p' | head -1)"
codesign --force --sign "${id:--}" "$app/Contents/MacOS/patchprime-scan"
codesign --force --sign "${id:--}" "$app"
codesign -dv "$app" 2>&1 | grep -E '^(Authority|Signature)=' | head -1
