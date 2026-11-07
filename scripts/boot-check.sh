#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
# After a restart or login: is PatchPrimeMac up, and is it as it was?
#   scripts/boot-check.sh save    records how things are now (before restarting)
#   scripts/boot-check.sh         compares with that
# Read-only, apart from the record it saves. Touches no audio.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
C="$root/build/patchprime-ctl"
# Kept with PatchPrimeMac's logs: it survives a restart, and the uninstaller removes it.
record="$HOME/Library/Logs/PatchPrimeMac/boot-record.txt"

snapshot() {
    echo "driver: $([ -d /Library/Audio/Plug-Ins/HAL/PatchPrimeMac.driver ] && echo installed || echo MISSING)"
    "$C" virtual-list 2>&1 | sed 's/^/virtual: /'
    "$C" state 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
s = json.load(sys.stdin)
for x in s["strips"]: print("strip:", x["slot"], x["label"], "muted" if x["muted"] else "", [e.get("plugin") or e["type"] for e in x["effects"]])
for b in s["buses"]: print("bus:", b["slot"], b["label"])
for o in s["outputs"]: print("output:", o["slot"], o["label"])
print("hardware output:", s.get("hardwareOutputEnabled"), "| rate:", s.get("sampleRate"), "| buffer:", s.get("bufferFrames"), "| cue to:", s.get("cueOutput"))
' 2>/dev/null || echo "state: engine not reachable"
}

if [ "${1:-}" = "save" ]; then
    mkdir -p "$(dirname "$record")"
    snapshot > "$record"
    echo "Recorded in $record:"
    cat "$record"
    exit 0
fi

echo "== helper"
pid=$(pgrep -x PatchPrimeEngine)
[ -n "$pid" ] && ps -o pid=,lstart= -p "$pid" | sed 's/^/running since login? pid /' || echo "NOT RUNNING"
echo "system up since: $(date -r "$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')")"
echo "== engine"
"$C" status 2>&1 | head -12
echo "== defaults"
"$C" snapshot 2>/dev/null | /usr/bin/python3 -I -c 'import json,sys; s=json.load(sys.stdin); print("output:", s["defaultOutput"], "| input:", s["defaultInput"])' 2>/dev/null
echo "== plugins"
"$C" plugins-timing 2>&1 | grep -v dead | head
echo "== compared with before"
if [ -f "$record" ]; then
    diff <(cat "$record") <(snapshot) && echo "Same as before the restart."
else
    echo "(nothing recorded before)"
fi
echo "== helper log, last lines"
tail -5 "$HOME/Library/Logs/PatchPrimeMac/engine.log" 2>/dev/null
