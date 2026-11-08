#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
# Builds PatchPrimeMac.app, the GUI, into build/.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build -c release --product PatchPrimeMac
bin="$(swift build -c release --show-bin-path)"
app="$root/build/PatchPrimeMac.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/PatchPrimeMac" "$app/Contents/MacOS/PatchPrimeMac"
mkdir -p "$app/Contents/Resources"
cp "$root/docs/user-guide.md" "$app/Contents/Resources/user-guide.md"
cat > "$app/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>PatchPrimeMac</string>
	<key>CFBundleIdentifier</key><string>com.kingsqueak.patchprimemac</string>
	<key>CFBundleName</key><string>PatchPrimeMac</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$(cat "$root/packaging/VERSION")</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PL
id="$(security find-identity -v -p codesigning | sed -n 's/.*\([0-9A-F]\{40\}\).*/\1/p' | head -1)"
codesign --force --sign "${id:--}" "$app"
