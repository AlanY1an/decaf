#!/bin/sh
# Build the app, replace any running instance, and launch the fresh build.
#
# xcodebuild only updates the bundle on disk — a Caffeinate already sitting in
# the menu bar keeps running the old code, which makes UI changes look like
# they did not land. Always use this instead of launching by hand.
set -e

cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
[ -d Caffeinate.xcodeproj ] || xcodegen generate

echo "Building…"
xcodebuild -project Caffeinate.xcodeproj -scheme Caffeinate -configuration Debug \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build 2>&1 |
    grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" || true

APP=$(xcodebuild -project Caffeinate.xcodeproj -scheme Caffeinate -configuration Debug \
    -showBuildSettings 2>/dev/null |
    awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/Caffeinate.app
[ -d "$APP" ] || { echo "No product at $APP"; exit 1; }

if pgrep -f "Caffeinate.app/Contents/MacOS/Caffeinate" >/dev/null; then
    echo "Quitting the running instance…"
    osascript -e 'quit app "Caffeinate"' 2>/dev/null || true
    sleep 2
    pkill -f "Caffeinate.app/Contents/MacOS/Caffeinate" 2>/dev/null || true
    sleep 1
fi

echo "Launching $APP"
open "$APP"
