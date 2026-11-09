#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
# Installs and starts the engine helper for this user. No sudo needed.
# It's silent on hardware until `patchprime-ctl hardware on`.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
label=com.kingsqueak.patchprimemac.engine
dest="$HOME/Applications/PatchPrimeMac"
plist="$HOME/Library/LaunchAgents/$label.plist"
logs="$HOME/Library/Logs/PatchPrimeMac"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
# Wait until launchd has let go of the old one (it may take a moment to stop its
# plugins), or the new one can't be started in its place.
for _ in $(seq 50); do
    launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break
    sleep 0.1
done
mkdir -p "$dest" "$logs" "$HOME/Library/LaunchAgents"
rm -rf "$dest/PatchPrimeEngine.app"
cp -R "$root/build/PatchPrimeEngine.app" "$dest/"
cat > "$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$label</string>
	<key>Program</key><string>$dest/PatchPrimeEngine.app/Contents/MacOS/PatchPrimeEngine</string>
	<key>RunAtLoad</key><true/>
	<key>MachServices</key><dict><key>$label</key><true/></dict>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardOutPath</key><string>$logs/engine.log</string>
	<key>StandardErrorPath</key><string>$logs/engine.log</string>
	<key>AssociatedBundleIdentifiers</key><string>com.kingsqueak.patchprimemac</string>
</dict>
</plist>
PL
for try in 1 2 3; do
    launchctl bootstrap "gui/$(id -u)" "$plist" && break
    echo "Starting it failed; trying again ($try)."
    sleep 1
done
echo "Engine installed and started."
