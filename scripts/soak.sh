#!/bin/zsh
# A long run: logs the engine's state every 10 minutes and keeps the Mac from idle
# sleeping meanwhile. Usage: soak.sh [hours]. Stops by itself.
hours=${1:-24}
root="$(cd "$(dirname "$0")/.." && pwd)"
log="$HOME/Library/Logs/PatchPrimeMac/soak.log"
mkdir -p "${log:h}"
caffeinate -i -t $((hours * 3600)) &
keep=$!
echo "=== soak started $(date), $hours hours" >> "$log"
end=$(( $(date +%s) + hours * 3600 ))
while [ "$(date +%s)" -lt "$end" ]; do
    {
        echo "--- $(date '+%F %T')"
        timeout 12 "$root/build/patchprime-ctl" status || echo "ENGINE NOT ANSWERING"
        ps -o %cpu=,rss=,comm= -p "$(pgrep -x PatchPrimeEngine)" 2>/dev/null
        ps -o %cpu=,comm= -p "$(pgrep -x coreaudiod)" 2>/dev/null
    } >> "$log" 2>&1
    sleep 600
done
kill $keep 2>/dev/null
echo "=== soak finished $(date)" >> "$log"
