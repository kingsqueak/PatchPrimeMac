#!/bin/bash
# Spike S1: remove the test driver and restart coreaudiod. Run with sudo.
# This interrupts ALL audio on the Mac for a moment. Mute the amp first.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
rm -rf /Library/Audio/Plug-Ins/HAL/PatchPrimeMacSpike.driver
killall coreaudiod # launchd starts it again; SIP blocks launchctl kickstart here
echo "Removed. coreaudiod restarted."
