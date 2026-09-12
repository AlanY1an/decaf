#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
DEST="$HERE/Sources/DecafLiveDemo/App"
rm -rf "$DEST"
mkdir -p "$DEST"
for f in "$REPO"/App/*.swift; do
  [ "$(basename "$f")" = DecafApp.swift ] && continue
  cp "$f" "$DEST/"
done
# Only the window presenter is adapted: the product views remain unchanged.
python3 - "$DEST/UsageStatisticsWindow.swift" <<'PYISOLATE'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = 'router: router, tabRouter: tabRouter, commands: commands))'
assert s.count(needle) == 1, "Recheck demo isolation after presenter changes"
s = s.replace(needle, 'router: router, tabRouter: tabRouter, commands: commands, sessions: DemoEnvironment.shared.isolatedSessions()))')
s = s.replace('width: 1060, height: 820', 'width: 900, height: 820')
s = s.replace('window.center()', 'window.setFrameTopLeftPoint(NSPoint(x: NSScreen.main!.visibleFrame.maxX - 925, y: NSScreen.main!.visibleFrame.maxY - 62))')
p.write_text(s)
PYISOLATE
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
<key>CFBundleShortVersionString</key><string>0.3.3</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
