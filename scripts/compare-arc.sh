#!/usr/bin/env bash
# Times Arc and cha the same way (scripts/launchbench.swift), only while
# nobody is at this Mac, and leaves Arc as it found it (reopened in the
# background if it was running). Results go to build/check/compare-arc.txt.
set -uo pipefail
cd "$(dirname "$0")/.."
out=build/check/compare-arc.txt
mkdir -p build/check

[ -x build/launchbench ] || swiftc -O scripts/launchbench.swift -o build/launchbench

if ! ~/.local/bin/mac-idle >/dev/null 2>&1; then
  echo "Mac in use: comparison skipped"; exit 75
fi

arc_was_running=0
pgrep -x Arc >/dev/null && arc_was_running=1

{
  echo "== $(date '+%Y-%m-%d %H:%M') launch/quit, 5 runs each (ms)"
  build/launchbench build/cha.app 5 CHA_PROFILE="$PWD/build/bench-profile"
  # Someone may have come back during cha's runs: then leave Arc alone.
  if ~/.local/bin/mac-idle --min 60 >/dev/null 2>&1; then
    build/launchbench /Applications/Arc.app 5
  else
    echo "Mac in use again: Arc not measured"
  fi
} 2>&1 | tee "$out"

if [ "$arc_was_running" = 1 ] && ! pgrep -x Arc >/dev/null; then
  open -g -a Arc
fi
grep -q 'median Arc.app' "$out"
