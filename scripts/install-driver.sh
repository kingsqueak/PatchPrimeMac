#!/bin/bash
# Installs the PatchPrimeMac driver and removes the old test driver. Run with sudo.
# This interrupts ALL audio on the Mac for a moment. Turn amplifiers down first.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/build/driver/PatchPrimeMac.driver"
hal=/Library/Audio/Plug-Ins/HAL
[ -d "$src" ] || { echo "Not built: $src"; exit 1; }
rm -rf "$hal/PatchPrimeMac.driver" "$hal/PatchPrimeMacSpike.driver"
cp -R "$src" "$hal/PatchPrimeMac.driver"
chown -R root:wheel "$hal/PatchPrimeMac.driver"
killall coreaudiod # launchd starts it again; SIP blocks launchctl kickstart on it
echo "Installed. coreaudiod restarted."
