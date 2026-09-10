#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
DEST="$HERE/Sources/DecafLiveDemo/App"
mkdir -p "$DEST"
for f in "$REPO"/App/*.swift; do
  [ "$(basename "$f")" = DecafApp.swift ] && continue
  cp "$f" "$DEST/"
done
cd "$HERE"
swift build -c release
swift build --package-path "$REPO/Core" -c release --product decaf-bridge
APP="$HERE/.build/Decaf Demo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp .build/release/DecafLiveDemo "$APP/Contents/MacOS/DecafLiveDemo"
cp "$REPO/Core/.build/release/decaf-bridge" "$APP/Contents/Helpers/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DecafLiveDemo</string>
<key>CFBundleIdentifier</key><string>io.github.alany1an.decaf.live-demo</string>
<key>CFBundleName</key><string>Decaf Demo</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
