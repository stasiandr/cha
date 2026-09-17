#!/usr/bin/env bash
# Builds cha and leaves the app bundle at build/cha.app.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"

[ -d third_party/cef ] || scripts/fetch-cef.sh

cmake -S . -B build -G Ninja >/dev/null
ninja -C build cha

rm -rf build/cha.app
cp -R build/src/Release/cha.app build/cha.app
echo "built build/cha.app"
