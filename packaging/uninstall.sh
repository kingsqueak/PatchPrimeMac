#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
#
# Removes PatchPrimeMac from this Mac: the app, the engine, the driver, macOS's audio
# settings for its devices, its permissions, logs and caches, and the installer's
# receipt; and, if asked, the user's settings, presets and scenes. Run as root:
#
#   sudo uninstall.sh [--delete-settings]
#   uninstall.sh --user NAME [--delete-settings]      (root already, from the Uninstall app)
#
# It works from the installed app (Contents/Resources), from the DMG, or from the
# source tree. All audio on the Mac stops for a moment while coreaudiod restarts.
set -uo pipefail
[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
user="${SUDO_USER:-}"
delete_settings=0
while [ $# -gt 0 ]; do
    case "$1" in
        --user) user="$2"; shift 2 ;;
        --delete-settings) delete_settings=1; shift ;;
        *) echo "Unknown option $1"; exit 2 ;;
    esac
done
[ -n "$user" ] && [ "$user" != root ] || { echo "Say whose settings: --user NAME (or run with sudo)."; exit 2; }
uid="$(id -u "$user")"
home="$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')"
support="$home/Library/Application Support/PatchPrimeMac"
label=com.kingsqueak.patchprimemac.engine
app_id=com.kingsqueak.patchprimemac
hal=/Library/Audio/Plug-Ins/HAL
prefs=/Library/Preferences/Audio
as_user() { launchctl asuser "$uid" sudo -u "$user" "$@"; }
problems=()

# The driver tool: beside this script (in the app or the DMG), or in a source build.
ppdriver=""
for p in "$here/ppdriver" "$here/../build/driver/ppdriver" /Applications/PatchPrimeMac.app/Contents/Resources/ppdriver; do
    [ -x "$p" ] && { ppdriver="$p"; break; }
done

echo "1. Moving the default input and output off PatchPrimeMac's devices"
if [ -n "$ppdriver" ]; then
    as_user "$ppdriver" prepare-uninstall "$support/previous-defaults.txt" \
        || problems+=("couldn't move the default devices; check them in System Settings > Sound")
else
    problems+=("the driver tool wasn't found, so the defaults weren't moved; check them in System Settings > Sound")
fi

echo "2. Quitting the app and stopping the engine"
as_user osascript -e "tell application id \"$app_id\" to quit" >/dev/null 2>&1 || true
sleep 1
for pid in $(pgrep -u "$uid" -x PatchPrimeMac); do kill "$pid"; done
launchctl bootout "gui/$uid/$label" 2>/dev/null || true
for _ in $(seq 50); do launchctl print "gui/$uid/$label" >/dev/null 2>&1 || break; sleep 0.1; done
for pid in $(pgrep -u "$uid" -x PatchPrimeEngine); do kill "$pid"; done

echo "3. Removing its permissions (before the app goes: tccutil needs it)"
as_user tccutil reset All "$label" >/dev/null 2>&1 || true
as_user tccutil reset All "$app_id" >/dev/null 2>&1 || true

echo "4. Removing the app, the engine, logs, caches and preferences"
rm -f "$home/Library/LaunchAgents/$label.plist"
rm -rf /Applications/PatchPrimeMac.app "$home/Applications/PatchPrimeMac.app" "$home/Applications/PatchPrimeMac"
rm -rf "$home/Library/Logs/PatchPrimeMac" \
    "$home/Library/Caches/$app_id" "$home/Library/HTTPStorages/$app_id" \
    "$home/Library/Saved Application State/$app_id.savedState"
# cfprefsd caches preferences, so delete through it rather than just the file.
as_user defaults delete "$app_id" >/dev/null 2>&1 || true
as_user defaults delete "$label" >/dev/null 2>&1 || true
rm -f "$home/Library/Preferences/$app_id.plist" "$home/Library/Preferences/$label.plist"
/usr/bin/python3 -I -c "import _posixshmem; _posixshmem.shm_unlink('/ppmac.meters.$uid')" 2>/dev/null || true
if [ "$delete_settings" = 1 ]; then
    rm -rf "$support"
    echo "   Settings, presets and scenes deleted."
else
    rm -f "$support/previous-defaults.txt"
    echo "   Settings, presets and scenes kept in $support."
fi
for receipt in $(pkgutil --pkgs | grep -i '^com\.kingsqueak\.patchprimemac'); do
    pkgutil --forget "$receipt" >/dev/null 2>&1 || true
done

echo "5. Removing the driver and its entries in macOS's audio settings (audio stops for a moment)"
rm -rf "$hal/PatchPrimeMac.driver" "$hal/PatchPrimeMacSpike.driver"
killall coreaudiod 2>/dev/null # a fresh start without the driver
sleep 2
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
# A plain kill lets coreaudiod write its old settings back over the cleaned files; a
# hard kill can't, and it starts again from the clean ones.
killall -9 coreaudiod 2>/dev/null
# Apple's AirPlay helper can lose its link to a restarted coreaudiod and then
# re-register its driver hundreds of times a second, which keeps coreaudiod and every
# app using sound busy. Restarting it (it ignores a plain kill; launchd starts it
# again) avoids that.
sleep 2
killall -9 AirPlayXPCHelper 2>/dev/null

echo
left=$( (grep -l -a -i patchprimemac "$prefs"/*.plist 2>/dev/null; ls "$hal" | grep -i patchprime; \
    ls -d /Applications/PatchPrimeMac.app "$home/Library/LaunchAgents/$label.plist" 2>/dev/null) || true)
if [ -n "$left" ]; then
    echo "Still there:"; echo "$left"
else
    echo "PatchPrimeMac is removed."
fi
for p in "${problems[@]:-}"; do [ -n "$p" ] && echo "Note: $p"; done
exit 0
