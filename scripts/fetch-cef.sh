#!/usr/bin/env bash
# Downloads the stock CEF binary distribution into third_party/cef (~300 MB).
# It has no H.264/AAC: scripts/build-cef.sh builds the same version with them.
# VERSION here is the one both use.
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
