#!/bin/bash
# Removes the engine helper. No sudo needed.
# Add --delete-settings to remove saved settings as well; otherwise they're kept.
set -euo pipefail
label=com.kingsqueak.patchprimemac.engine
dest="$HOME/Applications/PatchPrimeMac"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
# Permission has to go first: tccutil needs the app to still exist.
tccutil reset Microphone "$label" 2>/dev/null || true
rm -rf "$dest"
rm -rf "$HOME/Library/Logs/PatchPrimeMac"
if [ "${1:-}" = "--delete-settings" ]; then
    rm -rf "$HOME/Library/Application Support/PatchPrimeMac"
    echo "Engine and settings removed."
else
    echo "Engine removed. Settings kept in ~/Library/Application Support/PatchPrimeMac."
fi
