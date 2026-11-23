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

# Signed with the Mac's Apple Development certificate when it has one. The
# linker's ad-hoc signature changes with every build, and macOS ties its
# permissions to the signature: Screen Recording (sharing a screen in Meet),
# the camera and the microphone were lost on each rebuild. A certificate's
# signature stays the same app to macOS. Parts already signed are skipped, so
# Chromium's framework is signed once, not on every build.
identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
sign() {  # path
  if [ -z "$identity" ]; then return; fi
  if codesign -dv "$1" 2>&1 | grep -qF "Authority=$identity"; then return; fi
  codesign --force --sign "$identity" --timestamp=none "$1" >/dev/null
}
app=build/src/Release/cha.app
sign "$app/Contents/Frameworks/Chromium Embedded Framework.framework"
for helper in "$app"/Contents/Frameworks/*Helper*.app; do sign "$helper"; done
# Only what changed is copied: the bundle carries ~300 MB of Chromium.
mkdir -p build/cha.app
# swiftc's dependency file sits next to the binary (Ninja needs it there);
# it stays out of the bundle, which is signed as a whole here.
rsync -a --delete --exclude /Contents/MacOS/cha.d --exclude /Contents/_CodeSignature \
  build/src/Release/cha.app/ build/cha.app/
# The icon (scripts/make-icon.swift draws it). CMake's resource copy is not
# run for a Swift target under Ninja, so it is put in here.
cp src/mac/cha.icns build/cha.app/Contents/Resources/cha.icns
rm -f build/cha.app/Contents/MacOS/cha.d
codesign --force --sign "${identity:--}" --timestamp=none build/cha.app >/dev/null
[ -n "$stamp" ] && echo "$stamp" > build/cha.stamp
# Tell LaunchServices about this build, so it can be the default browser.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f build/cha.app 2>/dev/null || true
echo "built build/cha.app"
