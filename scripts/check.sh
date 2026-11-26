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
  # A locked screen draws no windows and gives them no pointer: every
  # windowed check would fail for that alone (seen 2026-11-24, 02:40).
  if swift -e 'import CoreGraphics; exit((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int == 1 ? 0 : 1)' 2>/dev/null; then
    echo "screen locked: windowed run skipped"; exit 75
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
  CHA_TEST_PORT="${CHA_TEST_PORT:-}" CHA_DOWNLOADS="$PWD/$profile/Downloads" CHA_HEADLESS=$headless CHA_REAL_INPUT=$real_input CHA_TEST="$name" \
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

step "Peek (a local web server: localhost and 127.0.0.1 are two sites)"
site="build/check/peek-site"; rm -rf "$site"; mkdir -p "$site"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat > "$site/a.html" <<HTML
<title>A</title>
<a id=same href="/b.html" style="position:fixed;left:0;top:0;width:300px;height:100px;display:block">same</a>
<a id=other href="http://127.0.0.1:$port/b.html" style="position:fixed;left:0;top:120px;width:300px;height:100px;display:block">other</a>
HTML
echo "<title>B</title>b" > "$site/b.html"
cat > "$site/popup.html" <<HTML
<title>signin</title>
<button id=go onclick="window.open('http://127.0.0.1:$port/auth.html', 'auth', 'width=480,height=560')">Sign in</button>
<script>addEventListener('message', e => { document.title = 'GOT ' + e.data })</script>
HTML
cat > "$site/auth.html" <<HTML
<title>Sign in</title>
<script>setTimeout(() => { opener.postMessage('signed-in', '*'); close() }, 2500)</script>
HTML
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site" >/dev/null 2>&1 &
server=$!
sleep 0.5
CHA_TEST_PORT=$port run_scenario peek 40; code=$?
CHA_TEST_PORT=$port run_scenario popup 30; pcode=$?
kill "$server" 2>/dev/null
grep -E 'CHECK ' build/check/peek.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/peek.log; then
  echo "peek FAILED"; failed=$((failed + 1))
fi
step "a sign-in popup (window.opener, closes itself)"
grep -E 'CHECK ' build/check/popup.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$pcode" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/popup.log; then
  echo "popup FAILED"; failed=$((failed + 1))
fi

step "video and sound: H.264/AAC (cha's own CEF build), VP9, AV1, Opus; ⌘W ends a playing page; ⇧⌘R"
site="build/check/media-site"; rm -rf "$site"; mkdir -p "$site"
cp scripts/fixtures/h264-aac.mp4 "$site/"; echo "<title>media</title>" > "$site/index.html"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site" >/dev/null 2>&1 &
server=$!
sleep 0.5
CHA_TEST_PORT=$port run_scenario media 50; code=$?
CHA_TEST_PORT=$port run_scenario hardreload 20; hard=$?
kill "$server" 2>/dev/null
grep -E 'CHECK |MEDIA|PLAY' build/check/media.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/media.log; then
  echo "media FAILED (stock CEF? scripts/build-cef.sh builds one with the codecs)"; failed=$((failed + 1))
fi
grep -E 'CHECK ' build/check/hardreload.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$hard" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/hardreload.log; then
  echo "⇧⌘R FAILED"; failed=$((failed + 1))
fi

step "picture in picture when leaving a call or a video tab"
run_scenario callpip 30; code=$?
grep -E 'CHECK ' build/check/callpip.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/callpip.log; then
  echo "call picture in picture FAILED"; failed=$((failed + 1))
fi

step "Google Calendar: sign-in, next meeting, Join, reminders (fake Google)"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
glog=build/check/google-fake.log; rm -f "$glog"
python3 scripts/google-fake.py "$port" "$glog" & server=$!
sleep 0.5
CHA_GOOGLE_BASE="http://127.0.0.1:$port" CHA_GOOGLE_LOG="$PWD/$glog" run_scenario calendar 30; code=$?
kill "$server" 2>/dev/null
grep -E 'CHECK ' build/check/calendar.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/calendar.log; then
  echo "calendar FAILED"; failed=$((failed + 1))
fi

step "Boosts: a site's own CSS, script and zapped things"
site="build/check/boost-site"; rm -rf "$site"; mkdir -p "$site"
echo '<title>boost</title><h1>Hello</h1><div class="ad"><p>an ad</p></div><p id="keep">keep</p>' > "$site/index.html"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site" >/dev/null 2>&1 &
server=$!
sleep 0.5
CHA_TEST_PORT=$port run_scenario boost 30; code=$?
kill "$server" 2>/dev/null
grep -E 'CHECK ' build/check/boost.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/boost.log; then
  echo "boost FAILED"; failed=$((failed + 1))
fi

step "Tidy Titles on the Mac's own model"
run_scenario tidy 60; code=$?
grep -E 'CHECK |SKIP' build/check/tidy.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/tidy.log; then
  echo "tidy FAILED"; failed=$((failed + 1))
fi

step "command bar: many results keep the field in view"
run_scenario commandbar 30; code=$?
grep -E 'CHECK ' build/check/commandbar.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/commandbar.log; then
  echo "commandbar FAILED"; failed=$((failed + 1))
fi

step "Search All Tabs: titles, addresses, pages' text, every space"
run_scenario tabsearch 30; code=$?
grep -E 'CHECK ' build/check/tabsearch.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/tabsearch.log; then
  echo "tabsearch FAILED"; failed=$((failed + 1))
fi

step "Easels: drawn, written, framed, kept"
run_scenario easel 30; code=$?
grep -E 'CHECK ' build/check/easel.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/easel.log; then
  echo "easel FAILED"; failed=$((failed + 1))
fi

step "Notes: written, kept, back after reopening"
run_scenario notes 30; code=$?
grep -E 'CHECK ' build/check/notes.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/notes.log; then
  echo "notes FAILED"; failed=$((failed + 1))
fi

step "Chrome extensions: installed from a CRX, running after a restart"
site="build/check/ext-site"; rm -rf "$site"; mkdir -p "$site/src"
echo '<title>ext</title><p>page</p>' > "$site/index.html"
printf '%s' '{"manifest_version": 3, "name": "cha probe", "version": "1.0", "action": {"default_popup": "popup.html"}, "content_scripts": [{"matches": ["<all_urls>"], "js": ["c.js"], "run_at": "document_start"}]}' > "$site/src/manifest.json"
echo '<title>probe popup</title><p>popup</p>' > "$site/src/popup.html"
echo "document.documentElement.dataset.ext = 'yes';" > "$site/src/c.js"
python3 - "$site" <<'PY'
import io, struct, sys, zipfile, os
site = sys.argv[1]
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as z:
    for name in ("manifest.json", "c.js", "popup.html"):
        z.write(os.path.join(site, "src", name), name)
header = b""
open(os.path.join(site, "abcdefghijklmnopabcdefghijklmnop.crx"), "wb").write(b"Cr24" + struct.pack("<II", 3, len(header)) + header + buf.getvalue())
PY
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site" >/dev/null 2>&1 &
server=$!
sleep 0.5
CHA_TEST_PORT=$port run_scenario extensions 30; code=$?
profile="build/check/profile-extensions"; cp build/check/extensions.log build/check/extensions-1.log
# The same profile again, as after a restart (run_scenario would start afresh).
CHA_TEST_PORT=$port CHA_HEADLESS=1 CHA_TEST=extensions CHA_PROFILE="$PWD/$profile" CHA_DOWNLOADS="$PWD/$profile/Downloads" \
  timeout 30 build/cha.app/Contents/MacOS/cha >build/check/extensions-2.log 2>&1; code2=$?
kill "$server" 2>/dev/null
grep -hE 'CHECK ' build/check/extensions-1.log build/check/extensions-2.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || [ "$code2" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/extensions-1.log \
  || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/extensions-2.log; then
  echo "extensions FAILED"; failed=$((failed + 1))
fi

step "Claude: the MCP tools through cha-mcp, as Claude Code calls them"
site="build/check/claude-site"; rm -rf "$site"; mkdir -p "$site"
cat > "$site/index.html" <<'HTML'
<!doctype html><title>Claude probe</title><h1>Probe page</h1>
<label for=q>Your name</label> <input id=q placeholder="Type a name">
<button onclick="document.getElementById('out').textContent='Hello, '+q.value; document.title='Greeted '+q.value">Greet</button>
<p id=out></p><input type=checkbox id=c><label for=c>Remember me</label>
<form action="/page2.html"><input name=s placeholder=search></form><a href="/page2.html">Second page</a>
<p><input type=range id=r min=0 max=100 value=0 style="width:200px" aria-label="Volume">
<span id=h onmouseenter="this.textContent='hovered'">hover me</span></p>
<div style="height:3000px"></div><p>Bottom marker</p>
HTML
echo '<!doctype html><title>Page two</title><h1>Two</h1>' > "$site/page2.html"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site" >/dev/null 2>&1 &
server=$!
profile="$PWD/build/check/profile-claude"; rm -rf "$profile"; mkdir -p "$profile"
CHA_HEADLESS=1 CHA_TEST=claude CHA_PROFILE="$profile" build/cha.app/Contents/MacOS/cha >build/check/claude.log 2>&1 &
cha=$!
for _ in $(seq 40); do [ -x "$profile/cha-mcp" ] && grep -q 'CLAUDE listening' build/check/claude.log && break; sleep 0.5; done
timeout 120 python3 scripts/claude-check.py "$profile" "$port" | tee build/check/claude-check.log; code=${PIPESTATUS[0]}
kill "$cha" "$server" 2>/dev/null; wait "$cha" 2>/dev/null
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/claude-check.log; then
  echo "claude FAILED"; failed=$((failed + 1))
fi

step "Sync: two Macs (two profiles) through a local cloudsync server"
server_bin="$HOME/personal/cloudsync/target/release/cloudsync-server"
if [ ! -x "$server_bin" ]; then
  echo "skipped: no $server_bin (cargo build -p cloudsync-server --release in ~/personal/cloudsync)"
else
  sync_data="$PWD/build/check/sync-server"; rm -rf "$sync_data"; mkdir -p "$sync_data"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  CLOUDSYNC_DATA="$sync_data" CLOUDSYNC_ADDR="127.0.0.1:$port" "$server_bin" >build/check/sync-server.log 2>&1 &
  server=$!
  sleep 1
  a_profile="$PWD/build/check/profile-sync-a"; b_profile="$PWD/build/check/profile-sync-b"
  rm -rf "$a_profile" "$b_profile"
  code_file="$PWD/build/check/sync-code"; rm -f "$code_file"
  sync_ok=1
  for step_role in b1:b a:a b2:b a2:a; do
    role="${step_role%%:*}"; who="${step_role##*:}"
    profile=$([ "$who" = a ] && echo "$a_profile" || echo "$b_profile")
    CHA_SYNC_URL="http://127.0.0.1:$port" CHA_SYNC_ROLE="$role" CHA_SYNC_CODE_FILE="$code_file" \
      CHA_HEADLESS=1 CHA_TEST=sync CHA_PROFILE="$profile" CHA_DOWNLOADS="$profile/Downloads" \
      timeout 40 build/cha.app/Contents/MacOS/cha >"build/check/sync-$role.log" 2>&1 || sync_ok=0
    grep -E 'CHECK |SKIP' "build/check/sync-$role.log" | sed 's/^.*cha\[[^]]*\] //'
    grep -q 'CHECKS passed=[0-9]* failed=0' "build/check/sync-$role.log" || sync_ok=0
  done
  kill "$server" 2>/dev/null
  if [ "$sync_ok" != 1 ]; then echo "sync FAILED"; failed=$((failed + 1)); fi
fi

step "Tab flows: hundreds of random switches, opens, closes, splits; picture in picture across them"
run_scenario flows 100; code=$?
grep -E 'CHECK |FLOWS seed' build/check/flows.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/flows.log; then
  echo "flows FAILED (CHA_SEED=<seed above> replays it)"; failed=$((failed + 1))
fi

step "Split View: two tabs side by side"
run_scenario split 30; code=$?
grep -E 'CHECK ' build/check/split.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/split.log; then
  echo "split FAILED"; failed=$((failed + 1))
fi

step "sound: a tab's speaker and mute, the mini player"
run_scenario sound 30; code=$?
grep -E 'CHECK ' build/check/sound.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/sound.log; then
  echo "sound FAILED"; failed=$((failed + 1))
fi

step "links to other apps (slack:, mailto:) go to macOS"
run_scenario external 30; code=$?
grep -E 'CHECK ' build/check/external.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/external.log; then
  echo "external links FAILED"; failed=$((failed + 1))
fi

step "sign-ins survive a restart (default profile and a space's own)"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cookies=build/check/cookies.log; rm -f "$cookies"
python3 scripts/cookie-server.py "$port" "$cookies" &
server=$!
sleep 0.5
rm -rf build/check/profile-persist
for phase in setup write read; do
  CHA_PHASE=$phase CHA_HEADLESS=1 CHA_TEST=persist CHA_TEST_PORT=$port CHA_PROFILE="$PWD/build/check/profile-persist" \
    build/cha.app/Contents/MacOS/cha >"build/check/persist-$phase.log" 2>&1
done
kill "$server" 2>/dev/null
grep '^/check' "$cookies"
for p in default work; do
  if ! grep -q "^/check p=$p cookies=kept=k1,session=s1$" "$cookies"; then
    echo "persist FAILED: the $p profile lost its cookies"; failed=$((failed + 1))
  fi
done

step "a force quit leaves no Chromium session to restore"
p="$PWD/build/check/profile-killed"; rm -rf "$p"
CHA_HEADLESS=1 CHA_TEST=idle CHA_PROFILE="$p" build/cha.app/Contents/MacOS/cha >build/check/killed-1.log 2>&1 &
pid=$!; sleep 6; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
pkill -9 -f "profile-killed" 2>/dev/null
wrote=$(ls "$p/Default/Sessions" 2>/dev/null | wc -l | tr -d ' ')
CHA_HEADLESS=1 CHA_TEST=bench CHA_PROFILE="$p" build/cha.app/Contents/MacOS/cha >build/check/killed-2.log 2>&1
if [ "$wrote" -gt 0 ] && grep -q 'SESSIONS removed .*/Default/Sessions' build/check/killed-2.log; then
  echo "ok: Chromium's session ($wrote files) dropped at the next start"
else
  echo "force-quit FAILED: session files $wrote, $(grep -c SESSIONS build/check/killed-2.log) removed"; failed=$((failed + 1))
fi

step "profiles: accounts per space"
run_scenario profiles 40; code=$?
grep -E 'CHECK ' build/check/profiles.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/profiles.log; then
  echo "profiles FAILED"; failed=$((failed + 1))
fi

step "a download"
run_scenario download 30; code=$?
grep -E 'CHECK ' build/check/download.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/download.log; then
  echo "download FAILED"; failed=$((failed + 1))
fi

step "links that want a new tab, and ⌘ shortcuts over a page"
run_scenario newtablinks 30; code=$?
grep -E 'CHECK ' build/check/newtablinks.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/newtablinks.log; then
  echo "new-tab links FAILED"; failed=$((failed + 1))
fi

step "the window comes back (⌘N)"
run_scenario window 20; code=$?
grep -E 'CHECK ' build/check/window.log | sed 's/^.*cha\[[^]]*\] //'
if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/window.log; then
  echo "window FAILED"; failed=$((failed + 1))
fi

step "⌘Q with a page in front, and the close button"
for sc in quitkey closewindow; do
  if run_scenario "$sc" 15 && grep -q 'TIMING shutdown-done' "build/check/$sc.log"; then
    echo "$sc: quits ($(grep -o 'quit-requested [0-9]*' build/check/$sc.log | head -1), $(grep -o 'shutdown-done [0-9]*' build/check/$sc.log))"
  else
    echo "$sc FAILED: did not quit"; failed=$((failed + 1))
  fi
done

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

if [ "$mode" = window ] && [ "$real_input" = 1 ]; then
  step "Meet's floating window (document picture in picture, on screen)"
  run_scenario docpip 30; code=$?
  grep -E 'CHECK ' build/check/docpip.log | sed 's/^.*cha\[[^]]*\] //'
  if [ "$code" -ne 0 ] || ! grep -q 'CHECKS passed=[0-9]* failed=0' build/check/docpip.log; then
    echo "docpip FAILED"; failed=$((failed + 1))
  fi
fi

if [ "$mode" = window ] && [ "$real_input" = 1 ] && [ "$(swift -e 'import AppKit; print(NSScreen.screens.count)' 2>/dev/null)" -gt 1 ]; then
  step "a link from an app in front, windowed and full screen (display 1, takes focus)"
  for m in window fullscreen; do
    if scripts/linktest/run.sh "$m" >"build/check/linktest-$m.log" 2>&1; then echo "$m: little window over the app"
    else grep -E 'FAIL' "build/check/linktest-$m.log"; echo "linktest $m FAILED"; failed=$((failed + 1)); fi
  done
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
