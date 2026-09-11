#!/bin/bash
# Builds two isolated apps for a real Sparkle installation/relaunch test.
# Never builds a production Decaf bundle, changes its preferences, or publishes.
set -euo pipefail
cd "$(dirname "$0")/../../.."
REPO="$PWD"
OUT="$REPO/build/updater-smoke"
SPARKLE="${DECAF_SPARKLE_BIN:-$REPO/build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
FRAMEWORK="$(dirname "$SPARKLE")/Sparkle.xcframework/macos-arm64_x86_64"
IDENTITY="${DECAF_SIGN_IDENTITY:?Set DECAF_SIGN_IDENTITY to your Developer ID Application identity}"
PUBLIC_KEY="$("$SPARKLE/generate_keys" --account io.github.alany1an.decaf -p)"
mkdir -p "$OUT/feed" "$OUT/install" "$OUT/new"
swiftc -swift-version 5 -parse-as-library -framework Sparkle -F "$FRAMEWORK" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    App/AppUpdater.swift App/UpdateGuideView.swift App/WindowAppearance.swift \
    docs/assets/updater-smoke/UpdaterSmoke.swift \
    -o "$OUT/UpdaterSmoke"
for BUILD in 41 42; do
    if [ "$BUILD" = 41 ]; then APP="$OUT/install/DecafUpdaterSmoke.app"; else APP="$OUT/new/DecafUpdaterSmoke.app"; fi
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
    cp "$OUT/UpdaterSmoke" "$APP/Contents/MacOS/UpdaterSmoke"
    ditto "$FRAMEWORK/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    python3 - "$APP" "$BUILD" "$PUBLIC_KEY" <<'PY'
import plistlib,sys
from pathlib import Path
app, build, key = sys.argv[1:]
plist = dict(CFBundleIdentifier='io.github.alany1an.decaf.updater-smoke',
    CFBundleName='Decaf updater test', CFBundleExecutable='UpdaterSmoke',
    CFBundlePackageType='APPL', CFBundleVersion=build,
    CFBundleShortVersionString='0.3.1-test.'+build, LSMinimumSystemVersion='14.0',
    SUFeedURL='http://127.0.0.1:8894/appcast.xml', SUPublicEDKey=key,
    SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
    SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False,
    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
    NSAppTransportSecurity=dict(NSAllowsArbitraryLoads=True))
Path(app,'Contents','Info.plist').write_bytes(plistlib.dumps(plist))
PY
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
done
ditto -c -k --keepParent "$OUT/new/DecafUpdaterSmoke.app" "$OUT/feed/DecafUpdaterSmoke.zip"
echo 'Test build 42: verify installation, relaunch and saved preferences.' > "$OUT/feed/DecafUpdaterSmoke.md"
"$SPARKLE/generate_appcast" --account io.github.alany1an.decaf --maximum-deltas 0 \
    --embed-release-notes --download-url-prefix http://127.0.0.1:8894/ "$OUT/feed"
"$SPARKLE/sign_update" --account io.github.alany1an.decaf --verify "$OUT/feed/appcast.xml"
echo "Serve $OUT/feed on 127.0.0.1:8894, then open $OUT/install/DecafUpdaterSmoke.app."
