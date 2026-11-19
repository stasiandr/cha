#!/usr/bin/env bash
# Where does the little window land when a link comes from an app in front
# of cha's main window? A real, activating run (it takes focus!) on display
# 1, the second monitor: a copy of cha with its own bundle id and profile,
# and scripts/linktest/sender.swift standing in for Slack.
#   scripts/linktest/run.sh [fullscreen]
set -uo pipefail
cd "$(dirname "$0")/../.."
mode="${1:-window}"
out=build/linktest; mkdir -p "$out"
swiftc -O -o "$out/sender" scripts/linktest/sender.swift || exit 1
app="$PWD/$out/cha-linktest.app"
if [ ! -d "$app" ] || [ build/cha.app/Contents/MacOS/cha -nt "$app/Contents/MacOS/cha" ]; then
  rm -rf "$app"; cp -cR build/cha.app "$app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.cha.linktest" "$app/Contents/Info.plist"
  codesign --force --deep -s - "$app" >/dev/null 2>&1
fi
profile="$PWD/$out/profile"; rm -rf "$profile"
CHA_SCREEN=1 CHA_LOUD=1 CHA_PROFILE="$profile" "$app/Contents/MacOS/cha" >"$out/cha.log" 2>&1 &
cha=$!
sleep 4
"$out/sender" 1 "$app" "data:text/html,<title>little</title><body style='background:%23c33'>little cha" "$mode" >"$out/sender.log" 2>&1 &
sender=$!
sleep $([ "$mode" = fullscreen ] && echo 7 || echo 5)
swift scripts/linktest/order.swift "$cha" "$sender" | tee "$out/order.txt"
screencapture -x -D 2 "$out/shot-$mode.png" 2>/dev/null
kill "$sender" "$cha" 2>/dev/null; sleep 1; kill -9 "$cha" 2>/dev/null
grep -E "LINK" "$out/cha.log" | sed 's/^.*cha\[[^]]*\] //'
grep -q '^PASS' "$out/order.txt"
