#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
# S3: signing and launch method, two builds each. Cleans up after itself.
K="$1"; H="$2"
root="$(cd "$(dirname "$0")/../.." && pwd)"
B="$root/spikes/s3-permission/build.sh"
cd "$root/build/s3"
L="$HOME/Library/Application Support/PatchPrimeMacS3/log.txt"
uid=$(id -u)
waitlog(){ for i in {1..75}; do grep -q 'result:\|M2 not found' "$L" 2>/dev/null && break; sleep 2; done; if [ -f "$L" ]; then grep -E 'build|mic status at start|answered|result' "$L" | sed 's/^[^ ]* pid [0-9]* //'; else echo 'NO LOG: helper did not run'; fi; }
# Test A: login item, self-signed, fresh id
for tag in a1 a2; do
  PPS3.app/Contents/MacOS/PPS3 --unregister >/dev/null 2>&1; sleep 1
  $B "$H" $tag "$K/pp.keychain-db" s3a >/dev/null 2>&1; rm -f "$L"
  echo "=== A login item, self-signed, build $tag"; PPS3.app/Contents/MacOS/PPS3 --register; waitlog
done
PPS3.app/Contents/MacOS/PPS3 --unregister >/dev/null 2>&1
agent(){ # name, signing, keychain, tag
  id=com.kingsqueak.patchprimemac.$1.helper
  P=~/Library/LaunchAgents/$id.plist
  launchctl bootout gui/$uid/$id 2>/dev/null
  $B "$2" $4 "$3" $1 >/dev/null 2>&1; rm -f "$L"
  cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$id</string>
<key>Program</key><string>$PWD/PPS3.app/Contents/Library/LoginItems/PPS3Helper.app/Contents/MacOS/PPS3Helper</string>
<key>RunAtLoad</key><true/>
<key>AssociatedBundleIdentifiers</key><string>com.kingsqueak.patchprimemac.$1</string>
</dict></plist>
PL
  launchctl bootstrap gui/$uid "$P"; waitlog
}
echo '=== B LaunchAgent, self-signed, build b1'; agent s3b "$H" "$K/pp.keychain-db" b1
echo '=== B LaunchAgent, self-signed, build b2'; agent s3b "$H" "$K/pp.keychain-db" b2
echo '=== C LaunchAgent, ad-hoc, build c1'; agent s3c - "" c1
echo '=== C LaunchAgent, ad-hoc, build c2'; agent s3c - "" c2
# cleanup
for n in s3b s3c; do id=com.kingsqueak.patchprimemac.$n.helper; launchctl bootout gui/$uid/$id 2>/dev/null; rm -f ~/Library/LaunchAgents/$id.plist; done
for n in s3 s3a s3b s3c; do tccutil reset Microphone com.kingsqueak.patchprimemac.$n.helper 2>&1 | tail -1; done
echo '=== crashes since start'; ls -t ~/Library/Logs/DiagnosticReports | grep -i pps3 | wc -l
echo done
