#!/usr/bin/env python3
"""Times cha's launch and quit, headless, against a throwaway profile.

    scripts/bench.py [runs]        # default 5

Each run starts build/cha.app with CHA_TEST=bench: the app loads its active
tab, then quits as ⌘Q does. Prints per-run marks (ms since the process
started) and the median of each:

  window        the main window with the sidebar is on screen
  tab-ready     the active tab's browser window exists
  first-load    the active tab's page finished loading
  quit          from the quit request to the process being gone
"""
import json
import os
import re
import statistics
import subprocess
import sys
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/cha.app/Contents/MacOS/cha")
PROFILE = os.path.join(ROOT, "build/bench-profile")

PAGE = "data:text/html,<title>Bench</title><h1>bench</h1>" + "<p>text</p>" * 200


def seed_state():
    """Three spaces with a dozen tabs, like a profile in real use."""
    def tab(url, pinned=False):
        return {"id": str(uuid.uuid4()), "url": url, "title": url, "isPinned": pinned}

    spaces = []
    for name, symbol, tint in [("Personal", "person", "blue"),
                               ("Work", "briefcase", "purple"),
                               ("Reading", "book", "green")]:
        tabs = [tab(PAGE)] + [tab(f"https://example.com/{name}/{i}") for i in range(4)]
        spaces.append({"id": str(uuid.uuid4()), "name": name, "symbol": symbol,
                       "tint": tint, "tabs": tabs, "activeTabID": tabs[0]["id"]})
    state = {"spaces": spaces, "activeSpaceID": spaces[0]["id"]}
    os.makedirs(PROFILE, exist_ok=True)
    with open(os.path.join(PROFILE, "state.json"), "w") as f:
        json.dump(state, f)


def run_once():
    seed_state()
    env = dict(os.environ, CHA_HEADLESS="1", CHA_TEST="bench", CHA_PROFILE=PROFILE)
    log_path = os.path.join(ROOT, "build/bench.log")
    start = time.time()
    with open(log_path, "w") as log:
        # Helpers inherit stderr, so the log goes to a file, not a pipe that
        # would stay open as long as any of them lives.
        proc = subprocess.Popen([APP], env=env, stdout=log, stderr=log)
        marks = {}
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            marks["hung"] = 1
            subprocess.run(["pkill", "-9", "-f", "build/cha.app/Contents"])
            proc.wait()
    end_ms = (time.time() - start) * 1000
    with open(log_path) as log:
        for line in log:
            m = re.match(r"TIMING (\S+) (\d+)", line)
            if m:
                marks[m.group(1)] = int(m.group(2))
    if "quit-requested" in marks:
        marks["quit"] = round(end_ms - marks["quit-requested"])
    marks["exit-code"] = proc.returncode
    return marks


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    keys = ["context-initialized", "window", "first-tab-created",
            "first-load-end", "windows-hidden", "browsers-closed", "loop-exited", "shutdown-done", "quit"]
    results = []
    for i in range(runs):
        marks = run_once()
        results.append(marks)
        print(f"{i + 1}/{runs} " + " ".join(f"{k}={marks.get(k, '-')}" for k in keys)
              + (" HUNG" if "hung" in marks else "")
              + f" exit={marks['exit-code']}", flush=True)
    print("median " + " ".join(
        f"{k}={statistics.median([r[k] for r in results if k in r]):.0f}"
        for k in keys if any(k in r for r in results)))
    bad = [r for r in results if "hung" in r or r["exit-code"] != 0]
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
