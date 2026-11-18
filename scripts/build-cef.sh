#!/usr/bin/env bash
# Builds cha's CEF from source with the proprietary codecs (H.264, AAC, HEVC)
# and puts it in third_party/cef. The stock CEF (scripts/fetch-cef.sh, Spotify's
# builds) plays only VP9/AV1/Opus, so sites that serve MP4 say "your browser
# can't play this video".
#
#   scripts/build-cef.sh            # checkout (~20 min, ~50 GB) + build (~1 h on
#                                   # an 18-core M-series, all cores) + install
#   scripts/build-cef.sh build      # rebuild only, sources already there
#   scripts/build-cef.sh install    # only copy the built distribution in
#
# CEF_WORK (default ~/personal/Sandboxes/cef-codecs) holds the sources; delete
# it afterwards, a rebuild for a new CEF version checks out again anyway.
# The version is the one scripts/fetch-cef.sh names: change it there.
#
# Two things the stock recipe doesn't cope with on Xcode 27:
#  - Xcode 27's SDK lists tbd targets (arm64e.x1) that Chromium's lld cannot
#    read ("malformed file"), so nothing links. The build uses a "hermetic"
#    Xcode instead (build/mac_files/xcode_binaries, which Chromium's own
#    bots use): links to Xcode 27's tools around the Command Line Tools'
#    MacOSX26.5.sdk, the SDK this Chromium is meant for.
#  - Xcode's metal stubs don't find the Metal Toolchain component
#    (xcodebuild -downloadComponent MetalToolchain); xcrun does, so the
#    hermetic toolchain's Metal tools call xcrun.
# And CEF's cefclient rule still names hermetic_xcode_path, which Chromium
# made private: it gets the real Xcode's path.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
what="${1:-all}"

version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/fetch-cef.sh)
commit=$(printf %s "$version" | sed -E 's/^[^+]*\+g([0-9a-f]+)\+.*/\1/')
branch=$(printf %s "$version" | sed -E 's/.*chromium-[0-9]+\.[0-9]+\.([0-9]+)\..*/\1/')
work="${CEF_WORK:-$HOME/personal/Sandboxes/cef-codecs}"
src="$work/src/chromium/src"
xcode_app=$(xcode-select -p | sed 's|/Contents/Developer$||')
sdk_version=26.5
sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX$sdk_version.sdk"
echo "CEF $version: branch $branch, commit $commit, in $work"

export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=0 use_remoteexec=false use_system_xcode=false"
automate() {
  nice -n 10 python3 "$work/automate-git.py" \
    --download-dir="$work/src" --depot-tools-dir="$work/depot_tools" \
    --branch="$branch" --checkout="$commit" --no-chromium-history --with-pgo-profiles \
    --arm64-build --no-debug-build --no-release-tests \
    --minimal-distrib-only --no-distrib-docs --no-distrib-symbols --no-distrib-archive "$@"
}

hermetic_xcode() {
  [ -d "$sdk" ] || { echo "missing $sdk: install the Command Line Tools"; exit 1; }
  local x="$xcode_app/Contents" h="$src/build/mac_files/xcode_binaries/Contents"
  local p="$x/Developer/Platforms/MacOSX.platform" hp="$h/Developer/Platforms/MacOSX.platform"
  local t="$x/Developer/Toolchains/XcodeDefault.xctoolchain" ht="$h/Developer/Toolchains/XcodeDefault.xctoolchain"
  rm -rf "$src/build/mac_files/xcode_binaries"
  mkdir -p "$hp/Developer/SDKs" "$ht/usr/bin"
  # Links everything in $1 into $2 but the names in $3 (made real above).
  link_all() { local from="$1" to="$2" skip=" $3 " f; for f in "$from"/*; do
    case "$skip" in *" $(basename "$f") "*) ;; *) ln -sfn "$f" "$to/$(basename "$f")" ;; esac; done; }
  link_all "$x" "$h" Developer
  link_all "$x/Developer" "$h/Developer" "Platforms Toolchains"
  link_all "$p" "$hp" Developer
  link_all "$p/Developer" "$hp/Developer" SDKs
  ln -sfn "$sdk" "$hp/Developer/SDKs/MacOSX$sdk_version.sdk"
  link_all "$t" "$ht" usr
  link_all "$t/usr" "$ht/usr" bin
  link_all "$t/usr/bin" "$ht/usr/bin" ""
  local metal
  metal=$(xcrun -f metal 2>/dev/null) || {
    xcodebuild -downloadComponent MetalToolchain; metal=$(xcrun -f metal); }
  local f n
  for f in "$(dirname "$metal")"/*; do
    n=$(basename "$f"); rm -f "$ht/usr/bin/$n"
    printf '#!/bin/sh\nDEVELOPER_DIR=%s/Contents/Developer exec xcrun %s "$@"\n' "$xcode_app" "$n" >"$ht/usr/bin/$n"
    chmod +x "$ht/usr/bin/$n"
  done
  sed -i '' "s|^          hermetic_xcode_path,\$|          \"$xcode_app\",|" "$src/cef/BUILD.gn"
}

if [ "$what" = all ]; then
  mkdir -p "$work"
  curl -fsSL -o "$work/automate-git.py" \
    "https://raw.githubusercontent.com/chromiumembedded/cef/$branch/tools/automate/automate-git.py"
  automate --no-build --no-distrib
fi
if [ "$what" = all ] || [ "$what" = build ]; then
  hermetic_xcode
  automate --no-update --force-build
fi

distrib="$src/cef/binary_distrib/cef_binary_${version}_macosarm64_minimal"
[ -d "$distrib/Release/Chromium Embedded Framework.framework" ] || { echo "no build at $distrib"; exit 1; }
rm -rf "$repo/third_party/cef-previous"
[ -d "$repo/third_party/cef" ] && mv "$repo/third_party/cef" "$repo/third_party/cef-previous"
cp -R "$distrib" "$repo/third_party/cef"
echo "installed in third_party/cef (the old one is in third_party/cef-previous)"
echo "next: scripts/check.sh (its media step checks H.264/AAC)"
