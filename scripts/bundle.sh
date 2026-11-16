#!/usr/bin/env bash
# Builds cha and leaves the app bundle at build/cha.app, with the source stamp
# it was built from in build/cha.stamp (the launcher compares it with
# scripts/source-stamp to know when to rebuild).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

[ -d third_party/cef ] || scripts/fetch-cef.sh

# Taken before building: edits made during the build count as a change.
stamp="$(scripts/source-stamp 2>/dev/null || true)"

cmake -S . -B build -G Ninja >/dev/null
ninja -C build cha

# Only what changed is copied: the bundle carries ~300 MB of Chromium.
mkdir -p build/cha.app
rsync -a --delete build/src/Release/cha.app/ build/cha.app/
# The icon (scripts/make-icon.swift draws it). CMake's resource copy is not
# run for a Swift target under Ninja, so it is put in here.
cp src/mac/cha.icns build/cha.app/Contents/Resources/cha.icns
[ -n "$stamp" ] && echo "$stamp" > build/cha.stamp
# Tell LaunchServices about this build, so it can be the default browser.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f build/cha.app 2>/dev/null || true
echo "built build/cha.app"
