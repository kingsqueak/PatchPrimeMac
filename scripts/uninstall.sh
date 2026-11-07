#!/bin/bash
# Removes all of PatchPrimeMac: app, engine helper, driver, settings, logs, caches,
# permissions and macOS's audio settings for our devices. Run with sudo.
#
#   sudo scripts/uninstall.sh                  keeps your settings
#   sudo scripts/uninstall.sh --delete-settings  removes them too
#
# This interrupts ALL audio on the Mac for a moment. Turn amplifiers down first.
# Afterwards it runs footprint.sh and lists anything still left.
set -uo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
[ -n "${SUDO_USER:-}" ] || { echo "Run with sudo from your own account, not as root"; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
user="$SUDO_USER"
uid="$(id -u "$user")"
home="$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')"
support="$home/Library/Application Support/PatchPrimeMac"
label=com.kingsqueak.patchprimemac.engine
app_id=com.kingsqueak.patchprimemac
as_user() { launchctl asuser "$uid" sudo -u "$user" "$@"; }
problems=()

echo "1. Moving default input and output off PatchPrimeMac devices"
if [ -x "$root/build/driver/ppdriver" ]; then
    "$root/build/driver/ppdriver" prepare-uninstall "$support/previous-defaults.txt" \
        || problems+=("couldn't move the default devices")
else
    problems+=("ppdriver not built, so defaults weren't moved")
fi

echo "2. Quitting the app and stopping the engine"
as_user osascript -e "tell application id \"$app_id\" to quit" >/dev/null 2>&1 || true
sleep 1
for pid in $(pgrep -u "$uid" -x PatchPrimeMac); do kill "$pid"; done
launchctl bootout "gui/$uid/$label" 2>/dev/null || true
sleep 1
for pid in $(pgrep -u "$uid" -x PatchPrimeEngine); do kill "$pid"; done

echo "3. Removing permissions (before the apps, since tccutil needs them present)"
as_user tccutil reset All "$label" >/dev/null 2>&1 || true
as_user tccutil reset All "$app_id" >/dev/null 2>&1 || true

echo "4. Removing the app, helper, logs, caches and preferences"
rm -f "$home/Library/LaunchAgents/$label.plist"
rm -rf "$home/Applications/PatchPrimeMac" "$home/Applications/PatchPrimeMac.app" \
    /Applications/PatchPrimeMac.app
rm -rf "$home/Library/Logs/PatchPrimeMac" \
    "$home/Library/Caches/$app_id" "$home/Library/HTTPStorages/$app_id" \
    "$home/Library/Saved Application State/$app_id.savedState"
# cfprefsd caches preferences, so delete through it rather than just removing the file.
as_user defaults delete "$app_id" >/dev/null 2>&1 || true
as_user defaults delete "$label" >/dev/null 2>&1 || true
rm -f "$home/Library/Preferences/$app_id.plist" "$home/Library/Preferences/$label.plist"
if [ "${1:-}" = "--delete-settings" ]; then
    rm -rf "$support"
    echo "   Settings deleted."
else
    rm -f "$support/previous-defaults.txt"
    echo "   Settings kept in $support (run with --delete-settings to remove them)."
fi
/usr/bin/python3 -I -c "import _posixshmem; _posixshmem.shm_unlink('/ppmac.meters.$uid')" 2>/dev/null || true

echo "5. Removing the driver and cleaning macOS's audio settings (audio stops briefly)"
"$root/scripts/uninstall-driver.sh" --skip-prepare || problems+=("driver removal reported a problem")

echo
echo "Checking what's left:"
if [ "${1:-}" = "--delete-settings" ]; then
    PP_USER="$user" "$root/scripts/footprint.sh"
else
    PP_USER="$user" "$root/scripts/footprint.sh" | grep -v "Application Support/PatchPrimeMac"
fi
for p in "${problems[@]:-}"; do [ -n "$p" ] && echo "Problem: $p"; done
exit 0
