#!/bin/bash
# Removes the PatchPrimeMac driver and everything it left. Run with sudo.
# This interrupts ALL audio on the Mac for a moment. Turn amplifiers down first.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
hal=/Library/Audio/Plug-Ins/HAL
prefs=/Library/Preferences/Audio

# First, while the driver is still there: defaults off our devices, saved list gone.
if [ "${1:-}" != "--skip-prepare" ] && [ -x "$root/build/driver/ppdriver" ]; then
    "$root/build/driver/ppdriver" prepare-uninstall \
        "${SUDO_HOME:-$HOME}/Library/Application Support/PatchPrimeMac/previous-defaults.txt" || true
fi
rm -rf "$hal/PatchPrimeMac.driver" "$hal/PatchPrimeMacSpike.driver"
killall coreaudiod # a fresh start, with the driver gone
sleep 2

# macOS keeps a settings entry for every device it has seen. Remove ours.
for file in "$prefs/com.apple.audio.SystemSettings.plist" "$prefs/com.apple.audio.DeviceSettings.plist"; do
    [ -f "$file" ] || continue
    /usr/bin/python3 -I - "$file" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    data = plistlib.load(f)
def mentions(value):
    if isinstance(value, dict):
        return any(mentions(k) or mentions(v) for k, v in value.items())
    if isinstance(value, list):
        return any(mentions(v) for v in value)
    return isinstance(value, str) and 'patchprimemac' in value.lower()
def clean(value):
    if isinstance(value, dict):
        for key in [k for k in value if mentions(k)]:
            del value[key]
        for item in value.values():
            clean(item)
    elif isinstance(value, list):
        value[:] = [v for v in value if not mentions(v)]
        for item in value:
            clean(item)
clean(data)
with open(path, 'wb') as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
PY
done
# A plain kill lets coreaudiod write its old settings back over the clean files. A
# hard kill can't, and it starts again with the cleaned ones.
killall -9 coreaudiod
sleep 2
left=$(grep -l -a -i 'patchprimemac' "$prefs"/*.plist 2>/dev/null || true)
left="$left$(ls "$hal" | grep -i patchprime || true)"
if [ -n "$left" ]; then
    echo "Still mentions PatchPrimeMac: $left"
else
    echo "Removed. Nothing of ours left in $prefs."
fi
