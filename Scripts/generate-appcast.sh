#!/bin/bash
# Generate and verify the signed feed that ships beside the final notarized DMG.
# Usage: Scripts/generate-appcast.sh <dmg> <exported-app> <notes.md> <output-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$#" -eq 4 ] || { echo "Usage: $0 <dmg> <exported-app> <notes.md> <output-dir>" >&2; exit 2; }
DMG="$1"; APP="$2"; NOTES="$3"; OUTPUT="$4"
BIN="${DECAF_SPARKLE_BIN:-$PWD/build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
ACCOUNT="${DECAF_SPARKLE_ACCOUNT:-io.github.alany1an.decaf}"
for TOOL in generate_keys generate_appcast sign_update; do
    [ -x "$BIN/$TOOL" ] || { echo "Missing $TOOL in $BIN. Resolve the pinned Sparkle package first." >&2; exit 1; }
done
[ -f "$DMG" ] && [ -f "$NOTES" ] && [ -f "$APP/Contents/Info.plist" ] || {
    echo "DMG, exported app or release notes missing." >&2; exit 1;
}
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
[ "$PUBLIC_KEY" = "$("$BIN/generate_keys" --account "$ACCOUNT" -p)" ] || {
    echo "The signing key does not match this app's SUPublicEDKey. Refusing to generate a feed." >&2; exit 1;
}
NAME="Decaf-$VERSION.dmg"
[ "$(basename "$DMG")" = "$NAME" ] || { echo "DMG filename/version mismatch." >&2; exit 1; }
OWNER="${DECAF_GITHUB_OWNER:-AlanY1an}"
REPO="${DECAF_REPO_NAME:-decaf}"
PREFIX="https://github.com/$OWNER/$REPO/releases/download/v$VERSION/"
mkdir -p "$OUTPUT"
STAGE="$(mktemp -d "$OUTPUT/.appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/$NAME"
cp "$NOTES" "$STAGE/Decaf-$VERSION.md"
"$BIN/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 \
    --embed-release-notes --download-url-prefix "$PREFIX" \
    --link "https://github.com/$OWNER/$REPO/releases/tag/v$VERSION" "$STAGE"
"$BIN/sign_update" --account "$ACCOUNT" --verify "$STAGE/appcast.xml"
SIGNATURE="$(python3 - "$STAGE/appcast.xml" "$VERSION" "$BUILD" "$PREFIX$NAME" "$DMG" <<'PY'
import os, sys, xml.etree.ElementTree as ET
feed, version, build, url, dmg = sys.argv[1:]
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(feed).findall('./channel/item')
assert len(items) == 1, 'Expected exactly this release in the feed'
item = items[0]
assert item.findtext('s:version', namespaces=ns) == build, 'Build mismatch'
assert item.findtext('s:shortVersionString', namespaces=ns) == version, 'Version mismatch'
enclosure = item.find('enclosure')
assert enclosure.get('url') == url, 'Download URL mismatch'
assert int(enclosure.get('length')) == os.path.getsize(dmg), 'DMG size mismatch'
signature = enclosure.get('{'+ns['s']+'}edSignature')
assert signature, 'Unsigned update archive'
print(signature)
PY
)"
"$BIN/sign_update" --account "$ACCOUNT" --verify "$DMG" "$SIGNATURE"
cp "$STAGE/appcast.xml" "$OUTPUT/appcast.xml"
echo "Signed and verified: $OUTPUT/appcast.xml"
