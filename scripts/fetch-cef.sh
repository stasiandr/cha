#!/usr/bin/env bash
# Downloads the CEF binary distribution into third_party/cef (~300 MB).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="152.0.6+g708dc14+chromium-152.0.7977.83"
URL="https://cef-builds.spotifycdn.com/cef_binary_$(printf %s "$VERSION" | sed 's/+/%2B/g')_macosarm64.tar.bz2"

if [ -d third_party/cef ]; then
  echo "third_party/cef already present"
  exit 0
fi

mkdir -p third_party
cd third_party
echo "Downloading CEF $VERSION…"
curl -fL --progress-bar -o cef.tar.bz2 "$URL"
tar xjf cef.tar.bz2
rm cef.tar.bz2
mv cef_binary_* cef
