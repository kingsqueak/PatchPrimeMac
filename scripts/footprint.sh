#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
# Lists everything PatchPrimeMac has left on this Mac: files, launchd jobs, processes,
# background item records, permissions, shared memory and macOS audio settings.
# Read-only. Run as yourself (sudo is fine too; it then checks the invoking user).
# Exit status 0 means nothing found.
#
# The development tree (this source checkout) is not counted: it's the source.
set -uo pipefail
# Whose Mac account to check: PP_USER, else whoever ran sudo, else yourself. Under
# "sudo -u you", SUDO_USER is root, which would check the wrong home.
user="${PP_USER:-}"
[ -z "$user" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && user="$SUDO_USER"
[ -z "$user" ] && user="$(id -un)"
home="$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')"
uid="$(id -u "$user")"
found=0
hit() { echo "  $*"; found=1; }
section() { echo "$1"; }

section "Files"
listed=""
for p in \
    /Library/Audio/Plug-Ins/HAL/PatchPrimeMac.driver \
    /Library/Audio/Plug-Ins/HAL/PatchPrimeMacSpike.driver \
    /Applications/PatchPrimeMac.app \
    "$home/Applications/PatchPrimeMac" \
    "$home/Applications/PatchPrimeMac.app" \
    "$home/Library/Application Support/PatchPrimeMac" \
    "$home/Library/Logs/PatchPrimeMac" \
    "$home/Library/Caches/com.kingsqueak.patchprimemac" \
    "$home/Library/HTTPStorages/com.kingsqueak.patchprimemac" \
    "$home/Library/Saved Application State/com.kingsqueak.patchprimemac.savedState" \
    "$home/Library/Preferences/com.kingsqueak.patchprimemac.plist" \
    "$home/Library/Preferences/com.kingsqueak.patchprimemac.engine.plist"; do
    [ -e "$p" ] && { hit "$p"; listed="$listed  $p"$'\n'; }
done
# Anything else with our name in the usual places.
others=$(for dir in /Library/LaunchAgents /Library/LaunchDaemons "/Library/Application Support" \
    /Library/Preferences "$home/Library/LaunchAgents" "$home/Library/Preferences" \
    "$home/Library/Caches" "$home/Library/Containers" "$home/Library/Group Containers" \
    "$home/Library/Application Scripts" "$home/Library/Saved Application State" \
    "$home/Library/HTTPStorages" "$home/Library/WebKit" /private/var/db/receipts; do
    [ -d "$dir" ] && find "$dir" -maxdepth 1 -iname '*patchprime*' 2>/dev/null
done | sort -u)
while IFS= read -r p; do
    [ -n "$p" ] && ! grep -qxF "  $p" <<<"$listed" && hit "$p"
done <<<"$others"

section "Audio settings (/Library/Preferences/Audio)"
for f in /Library/Preferences/Audio/*.plist; do
    grep -q -a -i patchprimemac "$f" 2>/dev/null && hit "$f mentions PatchPrimeMac"
done

section "Processes"
ps -axo pid=,command= | grep -i patchprime | grep -v -e scripts/footprint -e scripts/uninstall -e scripts/soak -e grep | sed "s/^ */  /" | cut -c1-140 | grep . && found=1

section "launchd jobs (gui/$uid)"
launchctl print "gui/$uid" 2>/dev/null | grep -i patchprime | sed 's/^[[:space:]]*/  /' | sort -u | grep . && found=1

section "Background item records (sfltool)"
sfltool dumpbtm 2>/dev/null | grep -i -B3 -A3 patchprime | grep -iE 'identifier|url|name' \
    | sed 's/^[[:space:]]*/  /' | sort -u | grep . && found=1

section "Permissions (TCC)"
tcc="$home/Library/Application Support/com.apple.TCC/TCC.db"
if out=$(sqlite3 "$tcc" "select service, client from access where client like '%patchprime%'" 2>&1); then
    echo "$out" | sed 's/^/  /' | grep -v '^  $' && found=1
else
    echo "  (can't read TCC.db: give Terminal Full Disk Access to check this)"
fi

section "Shared memory"
/usr/bin/python3 -I - "$uid" <<'PY' && found=1
import os, sys, _posixshmem
for name in (f"/ppmac.meters.{sys.argv[1]}", "/ppmac.meters"):
    try:
        fd = _posixshmem.shm_open(name, os.O_RDONLY)
        os.close(fd)
        print(f"  {name}")
        sys.exit(0)
    except OSError:
        pass
sys.exit(1)
PY

if [ "$found" -eq 0 ]; then
    echo "Nothing of PatchPrimeMac's found."
fi
exit "$found"
