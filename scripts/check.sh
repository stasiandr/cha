#!/usr/bin/env bash
# cha's acceptance: build, then the headless scenarios against throwaway
# profiles, then the launch/quit bench. Nothing takes focus, plays sound or
# shows on screen, so it is safe to run while someone uses this Mac.
#
#   scripts/check.sh          # build + spaces + codes + bench
#   scripts/check.sh fast     # build + spaces
#   scripts/check.sh window   # build + spaces in a real, visible window;
#                             # exits 75 without running when the Mac is in use
#   CHA_SCREEN=1 scripts/check.sh window
#                             # the same on display 1 (a second monitor), even
#                             # while the Mac is in use: no focus taken, muted
#
# Pictures land in build/shots, logs in build/check. Exit code = failed steps.
set -uo pipefail
cd "$(dirname "$0")/.."
mode="${1:-full}"
mkdir -p build/check build/shots
failed=0

step() { printf '\n== %s\n' "$1"; }

headless=1
real_input="${CHA_REAL_INPUT:-}"  # set it to 1 when nobody is at the Mac
if [ "$mode" = window ]; then
  headless=
  if [ -n "${CHA_SCREEN:-}" ] && ! swift -e 'import AppKit; exit(NSScreen.screens.count > '"$CHA_SCREEN"' ? 0 : 1)' 2>/dev/null; then
    echo "display $CHA_SCREEN is not connected: windowed run skipped"; exit 75
  fi
  if [ "$real_input" = 1 ] || ~/.local/bin/mac-idle >/dev/null 2>&1; then
    real_input=1  # nobody at the Mac: hover and drags may move the real cursor
  elif [ -z "${CHA_SCREEN:-}" ]; then
    echo "Mac in use: windowed run skipped (CHA_SCREEN=<n> uses another display)"; exit 75
  fi
fi

run_scenario() {  # name, timeout seconds
  local name="$1" limit="$2" profile="build/check/profile-$1"
  rm -rf "$profile"
  CHA_HEADLESS=$headless CHA_REAL_INPUT=$real_input CHA_TEST="$name" \
    CHA_PROFILE="$PWD/$profile" \
    build/cha.app/Contents/MacOS/cha >"build/check/$name.log" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1; waited=$((waited + 1))
    if [ "$waited" -ge "$limit" ]; then
      echo "timed out after ${limit}s"
      pkill -9 -f "build/cha.app/Contents" ; return 1
    fi
  done
  wait "$pid"
}

step "build"
if ! nice -n 10 scripts/bundle.sh >build/check/build.log 2>&1; then
  grep -E 'error' build/check/build.log | head -20
  echo "build FAILED"; exit 1
fi
echo "ok"

step "spaces"
run_scenario spaces 90; code=$?
grep -E 'CHECK FAIL|CHECKS' build/check/spaces.log | sed 's/^.*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/spaces.log; then
  echo "spaces FAILED (exit $code)"; failed=$((failed + 1))
fi

step "links from other apps (little window)"
run_scenario openurl 30; code=$?
grep -E 'CHECK |CHECKS' build/check/openurl.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/openurl.log; then
  echo "links FAILED"; failed=$((failed + 1))
fi

step "picture in picture (plumbing; the floating window itself is not opened)"
run_scenario pip 30; code=$?
grep -E 'CHECK ' build/check/pip.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=2 failed=0' build/check/pip.log; then
  echo "pip FAILED"; failed=$((failed + 1))
fi

if [ "$mode" = window ]; then
  step "ui (clicks; hover and drags only with the real cursor)"
  run_scenario ui 60; code=$?
  grep -E 'CHECK (FAIL|skip)|CHECKS' build/check/ui.log | sed 's/^.*cha\[[^]]*\] //'
  if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/ui.log; then
    echo "ui FAILED (exit $code)"; failed=$((failed + 1))
  fi
fi

if [ "$mode" = full ]; then
  step "codes"
  run_scenario codes 40
  grep -E 'CODES' build/check/codes.log | sed 's/^.*cha\[[^]]*\] //'
  # The filled field must hold exactly the code the generator gave.
  fills=$(sed -nE 's/.*CODES (fill|boxes) [A-Z]+ \[([0-9]+)\] expected=([0-9]+)$/\2 \3/p' \
    build/check/codes.log | awk '$1 == $2' | wc -l | tr -d ' ')
  if grep -q 'FAIL' build/check/codes.log || [ "$fills" -ne 2 ]; then
    echo "codes FAILED"; failed=$((failed + 1))
  fi

  step "launch and quit"
  if ! scripts/bench.py 5; then echo "bench FAILED"; failed=$((failed + 1)); fi
fi

printf '\n%s\n' "$([ $failed -eq 0 ] && echo "ALL PASSED" || echo "$failed step(s) FAILED")"
exit $failed
