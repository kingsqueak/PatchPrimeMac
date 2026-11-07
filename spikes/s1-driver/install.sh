#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
# Spike S1: install the test driver and restart coreaudiod. Run with sudo.
# This interrupts ALL audio on the Mac for a moment. Mute the amp first.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Run with sudo"; exit 1; }
src="$(cd "$(dirname "$0")/../.." && pwd)/build/s1/PatchPrimeMacSpike.driver"
dst=/Library/Audio/Plug-Ins/HAL/PatchPrimeMacSpike.driver
[ -d "$src" ] || { echo "Not built: $src"; exit 1; }
rm -rf "$dst"
cp -R "$src" "$dst"
chown -R root:wheel "$dst"
killall coreaudiod # launchd starts it again; SIP blocks launchctl kickstart here
echo "Installed. coreaudiod restarted."
