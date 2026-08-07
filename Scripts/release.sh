#!/bin/bash
# release.sh — the whole signing / notarization / distribution pipeline (plan 06 §6).
#
#   archive → export → DMG → notarytool submit --wait → stapler → sha256 → appcast
#
# The version is read from project.yml's MARKETING_VERSION, which plan 06 §3 makes
# the single source of truth. An optional positional <version> is cross-checked
# against it, so a typo in a release command can never produce a mislabelled DMG.
#
# Usage:
#   Scripts/release.sh [--dry-run] [--skip-tests] [<version>]
#
#   --dry-run     Run every step that does not need credentials: tests, xcodegen,
#                 check-bridge, an UNSIGNED archive, and a real (unsigned) DMG with
#                 a real sha256. Signing, notarization, stapling and Gatekeeper
#                 assessment are reported as skipped. Missing credentials downgrade
#                 from fatal to a warning. Use this to test the script today.
#   --skip-tests  Skip `swift test --package-path Core` (plan 06 §10 checklist item 1).
#
# Three things this script CANNOT do for you, and refuses to fake (see the
# PENDING AUTHOR DECISIONS block below):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. A stored notarytool keychain profile.
#   3. A frozen bundle ID — project.yml still carries a placeholder.
# All three are checked up front, together, before a single minute is spent on an
# archive. A named missing prerequisite beats a codesign error at step 6.
#
# Idempotency: every artifact lands under build/release/<version>/ and each step
# clears its own stale output first, so a re-run after a fixed failure is safe.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

# --------------------------------------------------------------------------
# FROZEN IDENTITY (author decision, 2026-08-07, with the Caffeinate → Decaf
# rename). These were the last pending decisions; they are now settled.
# --------------------------------------------------------------------------

# The bundle ID that must never ship again. The old placeholder was not a
# legitimate reverse-DNS name — nobody owns caffeinate.dev — and a public build
# under it would bake it into the notarization record, the prefs domain and
# ~/Library/Application Support. It is frozen to io.github.alany1an.decaf in
# project.yml; this stays as a tripwire so a revert cannot ship silently.
PLACEHOLDER_BUNDLE_ID="dev.caffeinate.app"

# GitHub owner and repo name, frozen. Only used to render the download URL in
# the cask and appcast snippets. Still overridable for a fork or a rehearsal.
GITHUB_OWNER="${DECAF_GITHUB_OWNER:-AlanY1an}"
REPO_NAME="${DECAF_REPO_NAME:-decaf}"

# Overridable, but these are the intended defaults.
#   DECAF_SIGN_IDENTITY  full identity string, e.g.
#                       "Developer ID Application: Jane Doe (AB12CD34EF)"
#                       Unset → the script finds the sole Developer ID in the keychain.
#   DECAF_NOTARY_PROFILE the `xcrun notarytool store-credentials` profile name.
SIGN_IDENTITY="${DECAF_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${DECAF_NOTARY_PROFILE:-AC_NOTARY}"

APP_NAME="Decaf"
SCHEME="Decaf"
PROJECT="Decaf.xcodeproj"
MIN_MACOS="14.0"   # Core/Package.swift .macOS(.v14)

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

if [ -t 1 ]; then
    C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
    C_GREEN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_BOLD=""; C_RED=""; C_YELLOW=""; C_GREEN=""; C_DIM=""; C_OFF=""
fi

STEP_NO=0
step()  { STEP_NO=$((STEP_NO + 1)); printf '\n%s==> [%d] %s%s\n' "$C_BOLD" "$STEP_NO" "$1" "$C_OFF"; }
info()  { printf '    %s\n' "$1"; }
ok()    { printf '    %sOK%s %s\n' "$C_GREEN" "$C_OFF" "$1"; }
skip()  { printf '    %sSKIP%s %s\n' "$C_DIM" "$C_OFF" "$1"; }
warn()  { printf '    %sWARN%s %s\n' "$C_YELLOW" "$C_OFF" "$1" >&2; }
die()   { printf '\n%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$1" >&2; exit 1; }

# Blockers accumulate as newline-separated records so that ONE run reports every
# missing prerequisite. Discovering the notary profile is missing only after
# fixing the certificate and re-archiving is exactly the waste this avoids.
# (Plain string, not an array: /bin/bash on macOS is 3.2, where expanding an
# empty array under `set -u` is itself an error.)
BLOCKERS=""
BLOCKER_COUNT=0
blocker() {
    BLOCKER_COUNT=$((BLOCKER_COUNT + 1))
    BLOCKERS="${BLOCKERS}${BLOCKER_COUNT}. $1"$'\n'
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------

DRY_RUN=0
SKIP_TESTS=0
ARG_VERSION=""

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=1 ;;
        --skip-tests) SKIP_TESTS=1 ;;
        -h|--help)    usage 0 ;;
        -*)           echo "Unknown option: $1" >&2; usage 2 ;;
        *)
            [ -n "$ARG_VERSION" ] && { echo "Unexpected extra argument: $1" >&2; usage 2; }
            ARG_VERSION="$1"
            ;;
    esac
    shift
done

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s%s DRY RUN — no signing, no notarization, no upload, nothing published. %s\n' \
        "$C_BOLD" "$C_YELLOW" "$C_OFF"
fi

# ==========================================================================
# 1. Preflight — everything that can fail cheaply, fails here.
# ==========================================================================

step "Preflight"

# --- 1a. Tools ------------------------------------------------------------
MISSING_TOOLS=""
for tool in xcodegen xcodebuild xcrun hdiutil swift shasum git plutil; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -n "$MISSING_TOOLS" ]; then
    blocker "Missing command-line tools:$MISSING_TOOLS
       xcodegen comes from \`brew install xcodegen\`; the rest ship with Xcode
       and its command line tools (\`xcode-select --install\`)."
else
    ok "toolchain present ($(xcodebuild -version | head -1))"
fi

# --- 1b. Version ----------------------------------------------------------
# MARKETING_VERSION lives in project.yml (plan 06 §3) and is the only place a
# version number is authored. Strip any trailing comment and surrounding quotes.
VERSION="$(awk -F: '/^[[:space:]]*MARKETING_VERSION:/ {
        sub(/#.*/, "", $2); gsub(/[[:space:]"'\'']/, "", $2); print $2; exit
    }' project.yml)"

if [ -z "$VERSION" ]; then
    blocker "Could not read MARKETING_VERSION from project.yml.
       Plan 06 §3 makes it the single source of truth for the version number."
elif ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    blocker "MARKETING_VERSION in project.yml is '$VERSION', which is not X.Y.Z.
       The DMG name, the git tag and the cask version all derive from it."
else
    ok "version $VERSION (from project.yml MARKETING_VERSION)"
fi

# Fatal even in a dry run: unlike the missing credentials below, this is an
# unambiguous mistake by the caller. Continuing would quietly build the OTHER
# version than the one just asked for.
if [ -n "$ARG_VERSION" ] && [ -n "$VERSION" ] && [ "$ARG_VERSION" != "$VERSION" ]; then
    die "version argument '$ARG_VERSION' does not match project.yml's '$VERSION'.
   Bump MARKETING_VERSION in project.yml first (plan 06 §10 checklist item 2),
   or drop the argument to build whatever project.yml currently says."
fi

BUILD_NUMBER="$(awk -F: '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ {
        sub(/#.*/, "", $2); gsub(/[[:space:]"'\'']/, "", $2); print $2; exit
    }' project.yml)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# --- 1c. Bundle ID must not have regressed to the old placeholder ---------
BUNDLE_ID="$(awk -F: '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:/ {
        sub(/#.*/, "", $2); gsub(/[[:space:]"'\'']/, "", $2); print $2; exit
    }' project.yml)"

if [ -z "$BUNDLE_ID" ]; then
    blocker "Could not read PRODUCT_BUNDLE_IDENTIFIER from project.yml."
elif [ "$BUNDLE_ID" = "$PLACEHOLDER_BUNDLE_ID" ]; then
    blocker "BUNDLE ID HAS REVERTED TO THE RETIRED PLACEHOLDER '$PLACEHOLDER_BUNDLE_ID'.
       The frozen value is io.github.alany1an.decaf. This is the single most
       irreversible string in the project: it fixes the preferences domain, the
       login-item registration identity, the owner of
       ~/Library/Application Support/Decaf/, and the notarization record.
       Changing it after the first public release silently breaks every existing
       install. Restore it in project.yml (PRODUCT_BUNDLE_IDENTIFIER and
       bundleIdPrefix) before any build leaves this machine."
else
    ok "bundle ID $BUNDLE_ID (frozen)"
fi

# --- 1d. Developer ID signing identity ------------------------------------
TEAM_ID=""
IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEVELOPER_ID_LINES="$(printf '%s\n' "$IDENTITY_LIST" | grep '"Developer ID Application:' || true)"

if [ -n "$SIGN_IDENTITY" ]; then
    if printf '%s\n' "$DEVELOPER_ID_LINES" | grep -qF "$SIGN_IDENTITY"; then
        ok "signing identity (from DECAF_SIGN_IDENTITY): $SIGN_IDENTITY"
    else
        blocker "DECAF_SIGN_IDENTITY is set to:
           $SIGN_IDENTITY
       but no such Developer ID Application identity is in the keychain.
       Available codesigning identities:
$(printf '%s\n' "${IDENTITY_LIST:-  (none)}" | sed 's/^/         /')"
    fi
elif [ -z "$DEVELOPER_ID_LINES" ]; then
    blocker "NO 'Developer ID Application' CERTIFICATE IN THE KEYCHAIN.
       This is the one prerequisite with an unbounded lead time: it needs a paid
       Apple Developer Program membership (docs/launch/README-REVIEW.md §3 item 1
       — enrollment can take 24 hours to two weeks), then Xcode →
       Settings → Accounts → Manage Certificates → + → Developer ID Application.
       Without it there is no signature, so no notarization, so a clean Mac shows
       'Decaf is damaged and can't be opened'.
       Identities currently available for codesigning:
$(printf '%s\n' "${IDENTITY_LIST:-  (none)}" | sed 's/^/         /')
       Re-run with --dry-run to exercise everything up to and including the DMG."
else
    IDENTITY_MATCHES="$(printf '%s\n' "$DEVELOPER_ID_LINES" | grep -c . || true)"
    if [ "$IDENTITY_MATCHES" -gt 1 ]; then
        blocker "More than one Developer ID Application identity is present:
$(printf '%s\n' "$DEVELOPER_ID_LINES" | sed 's/^/         /')
       Pick one explicitly so the release is not signed by whichever the keychain
       happened to return first:
           DECAF_SIGN_IDENTITY='Developer ID Application: … (TEAMID)' Scripts/release.sh"
    else
        SIGN_IDENTITY="$(printf '%s\n' "$DEVELOPER_ID_LINES" \
            | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p')"
        ok "signing identity: $SIGN_IDENTITY"
    fi
fi

# The team ID is the parenthesised suffix of the identity; exportOptions.plist
# needs it, and there is no other reliable place to read it from.
if [ -n "$SIGN_IDENTITY" ]; then
    TEAM_ID="$(printf '%s' "$SIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
    if [ -z "$TEAM_ID" ]; then
        blocker "Could not parse a team ID out of the signing identity:
           $SIGN_IDENTITY
       Expected it to end in '(TEAMID)'. exportOptions.plist needs teamID."
    fi
fi

# --- 1e. notarytool credentials -------------------------------------------
# `notarytool store-credentials` writes a generic keychain item under the
# service com.apple.gke.notary.tool. That is an implementation detail, so treat a
# miss as inconclusive rather than fatal and confirm with notarytool itself
# (one cheap authenticated call) before declaring the profile absent.
NOTARY_OK=0
if security find-generic-password -s "com.apple.gke.notary.tool" -a "$NOTARY_PROFILE" \
        >/dev/null 2>&1; then
    NOTARY_OK=1
    ok "notarytool keychain profile '$NOTARY_PROFILE' found"
elif [ "$DRY_RUN" -eq 0 ]; then
    info "keychain lookup inconclusive; asking notarytool directly…"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --limit 1 \
            >/dev/null 2>&1; then
        NOTARY_OK=1
        ok "notarytool keychain profile '$NOTARY_PROFILE' works"
    fi
fi

if [ "$NOTARY_OK" -eq 0 ]; then
    blocker "NO STORED NOTARY CREDENTIALS FOR PROFILE '$NOTARY_PROFILE'.
       One-time setup, after the Apple Developer Program membership is active
       (plan 06 §6). Generate an app-specific password at appleid.apple.com, then:
           xcrun notarytool store-credentials '$NOTARY_PROFILE' \\
               --apple-id '<your-apple-id>' \\
               --team-id '${TEAM_ID:-<TEAMID>}' \\
               --password '<app-specific-password>'
       Use a different profile name by exporting DECAF_NOTARY_PROFILE.
       (If you are offline, this check cannot distinguish 'no credentials' from
       'no network' — verify with: xcrun notarytool history --keychain-profile '$NOTARY_PROFILE')"
fi

# --- 1f. Repo hygiene ------------------------------------------------------
GIT_DIRTY=0
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    GIT_DIRTY=1
fi
TAG="v$VERSION"
TAG_EXISTS=0
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    TAG_EXISTS=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    [ "$GIT_DIRTY" -eq 1 ] && warn "working tree is dirty (would block a real release)"
    [ "$TAG_EXISTS" -eq 1 ] && warn "tag $TAG already exists (would block a real release)"
    [ "$GIT_DIRTY" -eq 0 ] && [ "$TAG_EXISTS" -eq 0 ] && ok "git clean, tag $TAG free"
else
    if [ "$GIT_DIRTY" -eq 1 ]; then
        blocker "Working tree is dirty. A release must be reproducible from a
       committed state — otherwise the tag does not describe the DMG.
       Commit or stash, then re-run."
    fi
    if [ "$TAG_EXISTS" -eq 1 ]; then
        blocker "Tag $TAG already exists. Bump MARKETING_VERSION in project.yml,
       or delete the tag if this release was never published."
    fi
    [ "$GIT_DIRTY" -eq 0 ] && [ "$TAG_EXISTS" -eq 0 ] && ok "git clean, tag $TAG free"
fi

# CHANGELOG is a checklist item, not a hard gate (plan 06 §10 item 2).
if [ -f CHANGELOG.md ] && [ -n "$VERSION" ] && ! grep -q "$VERSION" CHANGELOG.md; then
    warn "CHANGELOG.md has no entry mentioning $VERSION (plan 06 §10 checklist item 2)"
fi

# --- 1g. Report ------------------------------------------------------------
if [ "$BLOCKER_COUNT" -gt 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\n%s%s--- %d prerequisite(s) missing — fatal for a real release, ' \
            "$C_BOLD" "$C_YELLOW" "$BLOCKER_COUNT"
        printf 'continuing because --dry-run ---%s\n' "$C_OFF"
        printf '%s\n' "$BLOCKERS" >&2
    else
        printf '\n%s%s--- CANNOT RELEASE: %d prerequisite(s) missing ---%s\n' \
            "$C_BOLD" "$C_RED" "$BLOCKER_COUNT" "$C_OFF" >&2
        printf '\n%s\n' "$BLOCKERS" >&2
        printf '%sNothing was built and nothing was published. Fix the above, or run\n' "$C_DIM"
        printf 'Scripts/release.sh --dry-run to rehearse everything that does not need\n'
        printf 'credentials (tests, project generation, bridge check, archive, DMG, sha256).%s\n' "$C_OFF" >&2
        exit 1
    fi
fi

# Past this point a real run has real credentials, so refuse to guess.
if [ "$DRY_RUN" -eq 0 ] && { [ -z "$VERSION" ] || [ -z "$SIGN_IDENTITY" ] || [ -z "$TEAM_ID" ]; }; then
    die "internal: preflight passed but version/identity/team are not all resolved"
fi

# In a dry run the version may still be missing; without it no paths can be built.
[ -z "$VERSION" ] && die "no usable MARKETING_VERSION — cannot continue even in a dry run"

# --------------------------------------------------------------------------
# Paths — all derived, all under build/ (gitignored).
# --------------------------------------------------------------------------
OUT_DIR="$REPO_ROOT/build/release/$VERSION"
ARCHIVE_PATH="$OUT_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
EXPORT_OPTIONS="$OUT_DIR/exportOptions.plist"
DMG_STAGE="$OUT_DIR/dmg-stage"
# The asset filename is load-bearing: the Homebrew cask URL and the Sparkle feed
# both interpolate it (plan 06 §7/§8 and the §10 checklist). Never rename it.
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"
APPCAST_ITEM="$OUT_DIR/appcast-item.xml"
MANIFEST="$OUT_DIR/release-manifest.txt"

mkdir -p "$OUT_DIR"

# ==========================================================================
# 2. Tests
# ==========================================================================

# Generation comes first: the app-level test bundle below needs the project, and
# regenerating afterwards could produce a different project than the one tested.
step "xcodegen generate"
xcodegen generate >/dev/null
ok "$PROJECT regenerated from project.yml"

# ==========================================================================
# 3. Tests
# ==========================================================================

step "Core test suite"
if [ "$SKIP_TESTS" -eq 1 ]; then
    skip "--skip-tests given (plan 06 §10 checklist item 1 says run them)"
else
    swift test --package-path Core 2>&1 | tail -3
    ok "swift test --package-path Core passed"
fi

step "App test bundle"
if [ "$SKIP_TESTS" -eq 1 ]; then
    skip "--skip-tests given"
elif ! grep -q '^  DecafAppTests:' project.yml; then
    skip "no DecafAppTests target in project.yml"
else
    # A logic bundle with no TEST_HOST, so nothing launches the app and this is
    # safe to run unattended. Same configuration as the archive below.
    # xcodebuild's status is read via PIPESTATUS rather than relied on through
    # the filter: under `pipefail` a passing run whose output simply did not
    # match the grep would abort the release, and a failing run must abort it.
    set +e
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$REPO_ROOT/build/release-test-dd" \
        -only-testing:DecafAppTests \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)" | tail -3
    APP_TEST_STATUS=${PIPESTATUS[0]}
    set -e
    [ "$APP_TEST_STATUS" -eq 0 ] || die "DecafAppTests failed (xcodebuild exit $APP_TEST_STATUS).
   Re-run without the output filter to see which test:
       xcodebuild test -project $PROJECT -scheme $SCHEME -configuration Release \\
           -destination 'platform=macOS' -only-testing:DecafAppTests"
    ok "DecafAppTests passed"
fi

# ==========================================================================
# 4. Bridge dependency discipline
# ==========================================================================
# decaf-bridge ships inside the bundle and is signed with it; a bridge that picked
# up a non-system dependency would fail notarization at step 8 rather than here
# (plan 06 §2, review decision R4).

step "check-bridge (linked-library whitelist, size, smoke)"
./Scripts/check-bridge.sh >/dev/null
ok "decaf-bridge links system libraries only, is under budget, and is silent"

# ==========================================================================
# 5. Archive
# ==========================================================================

step "xcodebuild archive"
rm -rf "$ARCHIVE_PATH"

if [ "$DRY_RUN" -eq 1 ] && [ -z "$SIGN_IDENTITY" ]; then
    info "unsigned archive (no Developer ID available)"
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        2>&1 | grep -E "error:|warning: .*\.swift|ARCHIVE (SUCCEEDED|FAILED)" || true
else
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        2>&1 | grep -E "error:|warning: .*\.swift|ARCHIVE (SUCCEEDED|FAILED)" || true
fi

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[ -d "$ARCHIVED_APP" ] || die "archive produced no $APP_NAME.app at:
       $ARCHIVED_APP
   Re-run without the output filter to see the full xcodebuild log:
       xcodebuild archive -project $PROJECT -scheme $SCHEME -configuration Release \\
           -destination 'generic/platform=macOS' -archivePath '$ARCHIVE_PATH'"
ok "archived $ARCHIVED_APP"

# The embedded bridge is the classic notarization rejection: it is copied in by a
# post-build script, so it is easy for it to end up unsigned or missing.
EMBEDDED_BRIDGE="$ARCHIVED_APP/Contents/Helpers/decaf-bridge"
[ -x "$EMBEDDED_BRIDGE" ] || die "embedded helper missing: Contents/Helpers/decaf-bridge
   The 'Embed decaf-bridge' post-build script in project.yml did not run or failed."
ok "embedded Contents/Helpers/decaf-bridge present"

# ==========================================================================
# 6. Verify signatures before spending time on notarization
# ==========================================================================

step "codesign --verify --deep --strict"
if [ -z "$SIGN_IDENTITY" ]; then
    skip "archive is unsigned (dry run without a Developer ID)"
else
    codesign --verify --deep --strict --verbose=2 "$ARCHIVED_APP" 2>&1 | sed 's/^/    /'
    codesign --verify --strict --verbose=2 "$EMBEDDED_BRIDGE" 2>&1 | sed 's/^/    /'
    # Hardened Runtime is required for notarization and is set in project.yml;
    # confirm it actually made it into the signature rather than trusting the
    # manifest, because a missing runtime flag is only reported by the notary
    # service, minutes later, as an unhelpful rejection.
    if ! codesign --display --verbose=2 "$ARCHIVED_APP" 2>&1 | grep -q 'flags=.*runtime'; then
        die "the archived app is signed WITHOUT the hardened runtime.
   Notarization will reject it. Check ENABLE_HARDENED_RUNTIME in project.yml."
    fi
    ok "app and embedded bridge signed, hardened runtime on"
fi

# ==========================================================================
# 7. Export
# ==========================================================================

step "xcodebuild -exportArchive"
rm -rf "$EXPORT_DIR"

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID:-TEAMID-UNKNOWN}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <!-- Notarization is driven explicitly at step 8 so that failures surface
         here with notarytool's log, not inside xcodebuild. -->
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST
plutil -lint "$EXPORT_OPTIONS" >/dev/null || die "generated exportOptions.plist is malformed"

if [ -z "$SIGN_IDENTITY" ]; then
    skip "exportArchive needs a Developer ID; taking the app straight out of the archive"
    info "exportOptions.plist that a real run would use: $EXPORT_OPTIONS"
    mkdir -p "$EXPORT_DIR"
    cp -R "$ARCHIVED_APP" "$EXPORT_DIR/"
else
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        2>&1 | grep -Ev '^$' | tail -5 | sed 's/^/    /'
fi

EXPORTED_APP="$EXPORT_DIR/$APP_NAME.app"
[ -d "$EXPORTED_APP" ] || die "export produced no $EXPORTED_APP"
ok "exported $EXPORTED_APP"

# ==========================================================================
# 8. DMG
# ==========================================================================
# Plain UDZO disk image, no create-dmg, no background art (plan 06 §6 step 4).

step "hdiutil create — $DMG_NAME"
rm -rf "$DMG_STAGE" "$DMG_PATH"
mkdir -p "$DMG_STAGE"
cp -R "$EXPORTED_APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null
[ -f "$DMG_PATH" ] || die "hdiutil produced no DMG at $DMG_PATH"
DMG_BYTES="$(stat -f%z "$DMG_PATH")"
ok "$DMG_NAME ($DMG_BYTES bytes)"

# ==========================================================================
# 9. Notarize
# ==========================================================================

step "xcrun notarytool submit --wait"
if [ "$NOTARY_OK" -eq 0 ] || [ -z "$SIGN_IDENTITY" ]; then
    skip "no notary credentials and/or no signature — nothing to submit"
    info "a real run would execute:"
    info "  xcrun notarytool submit '$DMG_PATH' --keychain-profile '$NOTARY_PROFILE' --wait"
else
    SUBMIT_LOG="$OUT_DIR/notarytool-submit.txt"
    if xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait 2>&1 | tee "$SUBMIT_LOG" | sed 's/^/    /'; then
        :
    fi
    SUBMISSION_ID="$(sed -n 's/^ *id: \([0-9a-f-]*\)$/\1/p' "$SUBMIT_LOG" | head -1)"
    if ! grep -q 'status: Accepted' "$SUBMIT_LOG"; then
        if [ -n "$SUBMISSION_ID" ]; then
            printf '\n%sNotary rejection detail:%s\n' "$C_BOLD" "$C_OFF" >&2
            xcrun notarytool log "$SUBMISSION_ID" \
                --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/    /' >&2
        fi
        die "notarization was not Accepted (submission ${SUBMISSION_ID:-unknown}).
   Full submit output: $SUBMIT_LOG
   The usual cause is an unsigned or non-hardened nested binary — check
   Contents/Helpers/decaf-bridge first (plan 06 risk table)."
    fi
    ok "notarization Accepted (submission $SUBMISSION_ID)"
fi

# ==========================================================================
# 10. Staple and verify
# ==========================================================================

step "stapler staple + Gatekeeper assessment"
if [ "$NOTARY_OK" -eq 0 ] || [ -z "$SIGN_IDENTITY" ]; then
    skip "nothing was notarized, so there is no ticket to staple"
    info "a real run would execute:"
    info "  xcrun stapler staple '$DMG_PATH'"
    info "  xcrun stapler staple '$EXPORTED_APP'"
    info "  xcrun stapler validate '$DMG_PATH'"
    info "  spctl --assess --type execute -vv '$EXPORTED_APP'"
else
    xcrun stapler staple "$DMG_PATH"      | sed 's/^/    /'
    xcrun stapler staple "$EXPORTED_APP"  | sed 's/^/    /'
    xcrun stapler validate "$DMG_PATH"    | sed 's/^/    /'
    # Both checks, because they fail independently: a stapled DMG can still hold
    # an app Gatekeeper refuses (plan 06 §6 step 6).
    spctl --assess --type execute -vv "$EXPORTED_APP" 2>&1 | sed 's/^/    /'
    ok "stapled and assessed"
    # The DMG changed when the ticket was stapled, so the checksum must be taken
    # after this step — a sha256 computed earlier would not match what users get.
    DMG_BYTES="$(stat -f%z "$DMG_PATH")"
fi

# ==========================================================================
# 11. Checksums and downstream snippets
# ==========================================================================

step "sha256 and downstream snippets"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
ok "sha256 $DMG_SHA256"

DOWNLOAD_URL="https://github.com/$GITHUB_OWNER/$REPO_NAME/releases/download/$TAG/$DMG_NAME"

# Sparkle is a V1.x item (plan 06 §7); the app has no SUFeedURL/SUPublicEDKey and
# no EdDSA key exists yet. Emit the entry anyway so the shape is reviewable, with
# the signature slot marked rather than filled with a plausible-looking fake.
cat > "$APPCAST_ITEM" <<XML
<!-- appcast <item> for $APP_NAME $VERSION — generated by Scripts/release.sh
     NOT YET WIRED UP: Sparkle 2 integration is a V1.x work item (plan 06 §7).
     Before this is real: generate the EdDSA key pair once (Sparkle's
     generate_keys), back it up offline, put SUPublicEDKey + SUFeedURL in
     App/Info.plist, and replace the edSignature below with the output of
     "sign_update $DMG_NAME". Rotating the public key later cuts off every
     existing user, so the key must be generated before the first public DMG. -->
<item>
    <title>$VERSION</title>
    <pubDate>$(date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
    <sparkle:version>$BUILD_NUMBER</sparkle:version>
    <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
    <enclosure url="$DOWNLOAD_URL"
               length="$DMG_BYTES"
               type="application/octet-stream"
               sparkle:edSignature="PENDING-RUN-SIGN-UPDATE" />
</item>
XML

# A malformed appcast breaks the update feed for every existing user at once, and
# nothing else in the pipeline would catch it. Validate the fragment inside a
# throwaway root that declares the sparkle namespace the prefixes need.
if command -v xmllint >/dev/null 2>&1; then
    {
        echo '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
        cat "$APPCAST_ITEM"
        echo '</channel></rss>'
    } | xmllint --noout - 2>&1 | sed 's/^/    /'
    ok "appcast item is well-formed XML"
fi
ok "appcast item written to $APPCAST_ITEM"

# ==========================================================================
# 12. Manifest
# ==========================================================================

{
    echo "$APP_NAME $VERSION — release artifacts"
    echo "generated $(date -u '+%Y-%m-%dT%H:%M:%SZ') by Scripts/release.sh"
    [ "$DRY_RUN" -eq 1 ] && echo "MODE: DRY RUN — unsigned, un-notarized, NOT distributable"
    echo
    echo "bundle id     $BUNDLE_ID"
    echo "build number  $BUILD_NUMBER"
    echo "dmg           $DMG_PATH"
    echo "bytes         $DMG_BYTES"
    echo "sha256        $DMG_SHA256"
    echo "download url  $DOWNLOAD_URL"
    echo "appcast item  $APPCAST_ITEM"
    echo "archive       $ARCHIVE_PATH"
} > "$MANIFEST"

printf '\n%s%s%s\n' "$C_BOLD" "----------------------------------------------------------------" "$C_OFF"
cat "$MANIFEST"
printf '%s%s%s\n' "$C_BOLD" "----------------------------------------------------------------" "$C_OFF"

# Homebrew cask fields (plan 06 §8). Printed, not written: the tap is a separate
# repository and this script must not touch anything outside build/.
printf '\nCask fields for %s/homebrew-decaf/Casks/decaf.rb:\n' "$GITHUB_OWNER"
printf '  version "%s"\n' "$VERSION"
printf '  sha256 "%s"\n' "$DMG_SHA256"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n%s%sDRY RUN COMPLETE.%s The DMG above is unsigned and un-notarized: it exists to\n' \
        "$C_BOLD" "$C_YELLOW" "$C_OFF"
    printf 'prove the pipeline runs, and it would show "Decaf is damaged" on any Mac\n'
    printf 'other than this one. Do not distribute it. Nothing was published.\n'
else
    printf '\n%sNext steps are MANUAL and are not performed by this script%s (plan 06 §10):\n' \
        "$C_BOLD" "$C_OFF"
    printf '  1. Clean-machine smoke test: install from the DMG on a Mac with no\n'
    printf '     developer certificates and confirm Gatekeeper stays silent.\n'
    printf '  2. git tag %s && git push origin %s\n' "$TAG" "$TAG"
    printf '  3. gh release create %s "%s" --notes-file <notes>\n' "$TAG" "$DMG_PATH"
    printf '     The asset filename must stay exactly %s.\n' "$DMG_NAME"
    printf '  4. Bump the cask version + sha256 in the tap repo and verify with a\n'
    printf '     clean `brew install --cask`.\n'
fi
