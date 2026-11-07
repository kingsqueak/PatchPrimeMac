#!/bin/bash
# Removes all of PatchPrimeMac (see packaging/uninstall.sh), then lists anything left.
#   sudo scripts/uninstall.sh [--delete-settings]
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/packaging/uninstall.sh" "$@"
echo
echo "Checking what's left:"
PP_USER="${SUDO_USER:-}" "$root/scripts/footprint.sh" | grep -v "Application Support/PatchPrimeMac"
