#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
# Builds PPS3.app with its login-item helper inside.
# Usage: build.sh [signing identity, default ad-hoc] [build tag] [keychain] [bundle id suffix]
# A different tag makes a different binary, as a new release would be.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../../build/s3"
id="${1:--}"
tag="${2:-one}"
keychain="${3:-}"
suffix="${4:-s3}"
app="$out/PPS3.app"
helper="$app/Contents/Library/LoginItems/PPS3Helper.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$helper/Contents/MacOS" "$out/src"
sed "s/@NAME@/PPS3/;s/@ID@/com.kingsqueak.patchprimemac.$suffix/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
sed "s/@NAME@/PPS3Helper/;s/@ID@/com.kingsqueak.patchprimemac.$suffix.helper/" "$here/Info.plist.in" > "$helper/Contents/Info.plist"
sed "s/com.kingsqueak.patchprimemac.s3.helper/com.kingsqueak.patchprimemac.$suffix.helper/" "$here/main.swift" > "$out/src/app.swift.tmp"
mkdir -p "$out/src/app" && mv "$out/src/app.swift.tmp" "$out/src/app/main.swift"
swiftc -O "$out/src/app/main.swift" -o "$app/Contents/MacOS/PPS3"
{ cat "$here/helper.swift"; echo "// tag"; } | sed "s/log(\"helper started: /log(\"helper build $tag started: /" > "$out/src/main.swift"
swiftc -O "$out/src/main.swift" -o "$helper/Contents/MacOS/PPS3Helper"
args=(--force --sign "$id")
[ -n "$keychain" ] && args+=(--keychain "$keychain")
codesign "${args[@]}" "$helper"
codesign "${args[@]}" "$app"
codesign -dv "$helper" 2>&1 | grep -E 'Signature|CDHash=|^Authority' | head -3
