#!/bin/bash
# Build the app, replace any running instance, and launch the fresh build.
#
# xcodebuild only updates the bundle on disk — a Decaf already sitting in
# the menu bar keeps running the old code, which makes UI changes look like
# they did not land. Always use this instead of launching by hand.
#
# bash, not sh, for PIPESTATUS: the xcodebuild output goes through a filter, and
# without it a failed build would be reported as a success.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || {
    echo "xcodegen missing. Run Scripts/bootstrap.sh once (it installs it via Homebrew)." >&2
    exit 1
}

# Always regenerate, never "only if the project is missing". project.yml is the
# single source of truth and XcodeGen globs App/ at generation time, so a project
# generated before a file was added simply does not contain that file — and the
# build fails with "cannot find X in scope" for a symbol that is right there on
# disk. Regenerating costs about a second and removes the whole class of bug.
echo "Generating project…"
xcodegen generate >/dev/null

echo "Building…"
set +e
xcodebuild -project Decaf.xcodeproj -scheme Decaf -configuration Debug \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build 2>&1 |
    grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

# Without this check a compile error leaves the PREVIOUS build in
# BUILT_PRODUCTS_DIR, and the script would cheerfully launch the stale app —
# the exact "my change did not land" confusion this script exists to prevent.
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "Build failed (xcodebuild exit $BUILD_STATUS). Not launching." >&2
    echo "For the full log, re-run without the output filter:" >&2
    echo "  xcodebuild -project Decaf.xcodeproj -scheme Decaf -configuration Debug build" >&2
    exit "$BUILD_STATUS"
fi

APP=$(xcodebuild -project Decaf.xcodeproj -scheme Decaf -configuration Debug \
    -showBuildSettings 2>/dev/null |
    awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/Decaf.app
[ -d "$APP" ] || { echo "No product at $APP" >&2; exit 1; }

# Quit Decaf, and also any build still running under the retired Caffeinate
# name. Two of them coexisted for a while after the rename — both holding a
# power assertion, two cups in the menu bar — because this script only ever
# knew the current name. Anyone upgrading across the rename hits the same thing.
for proc in "Decaf.app/Contents/MacOS/Decaf" "Caffeinate.app/Contents/MacOS/Caffeinate"; do
    pgrep -f "$proc" >/dev/null || continue
    echo "Quitting $(basename "${proc%%.app*}")…"
    osascript -e "quit app \"$(basename "${proc%%.app*}")\"" 2>/dev/null || true
    sleep 2
    pkill -f "$proc" 2>/dev/null || true
    sleep 1
done

echo "Launching $APP"
open "$APP"
