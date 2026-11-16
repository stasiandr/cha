#!/bin/bash
# Builds build/ChaLauncher.app — what hop, Dock and Finder open instead of
# build/cha.app (~/Applications/cha.app links to it). It rebuilds cha when the
# sources on disk differ from the last build, then opens it. The launcher
# itself doesn't depend on cha's sources: build it once.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ChaLauncher.app"
REPO="$(pwd -P)"

echo "==> building $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/ChaLauncher" scripts/launcher/main.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>cha</string>
    <key>CFBundleDisplayName</key>          <string>cha</string>
    <key>CFBundleIdentifier</key>           <string>dev.stasiandr.cha.launcher</string>
    <key>CFBundleExecutable</key>           <string>ChaLauncher</string>
    <key>CFBundleIconFile</key>             <string>cha</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <!-- Where to build cha from. -->
    <key>ChaRepo</key>                      <string>$REPO</string>
</dict>
</plist>
PLIST

cp src/mac/cha.icns "$APP/Contents/Resources/cha.icns"

codesign --force --sign - "$APP" 2> /dev/null || echo "   (codesign skipped)"
echo "Done: $REPO/$APP"
