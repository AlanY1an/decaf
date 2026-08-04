#!/bin/bash
# check-bridge.sh — caff-bridge dependency-discipline gate (plan 06 §2/§5, review decision R4).
#
# Verifies, for a built caff-bridge binary:
#   1. otool -L linked libraries are ONLY system libraries (/usr/lib, /System).
#   2. Binary size < 2 MB.
#   3. Smoke: a sample JSON event piped through exits 0 with empty stdout/stderr.
#
# Usage: check-bridge.sh [path-to-caff-bridge]
#   Without an argument, builds the release binary from Core/ first.

set -euo pipefail

cd "$(dirname "$0")/.."

MAX_SIZE_BYTES=$((2 * 1024 * 1024))

BRIDGE="${1:-}"
if [ -z "$BRIDGE" ]; then
    echo "==> Building caff-bridge (release)"
    swift build -c release --package-path Core --product caff-bridge
    BRIDGE="Core/.build/release/caff-bridge"
fi

if [ ! -x "$BRIDGE" ]; then
    echo "ERROR: caff-bridge binary not found at: $BRIDGE" >&2
    exit 1
fi

echo "==> Checking linked libraries (otool -L whitelist)"
# Skip line 1 (the binary's own name); every linked library must live under
# /usr/lib or /System — zero third-party, zero @rpath (plan 06 §2).
VIOLATIONS=$(otool -L "$BRIDGE" | tail -n +2 | awk '{print $1}' \
    | grep -vE '^(/usr/lib/|/System/)' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: caff-bridge links non-system libraries:" >&2
    echo "$VIOLATIONS" >&2
    exit 1
fi
echo "    OK: system libraries only"

echo "==> Checking binary size (< 2 MB)"
SIZE=$(stat -f%z "$BRIDGE")
if [ "$SIZE" -ge "$MAX_SIZE_BYTES" ]; then
    echo "ERROR: caff-bridge is ${SIZE} bytes (limit ${MAX_SIZE_BYTES})" >&2
    exit 1
fi
echo "    OK: ${SIZE} bytes"

echo "==> Smoke: sample event through stdin must exit 0, silently"
SAMPLE='{"v":1,"agent":"claude","event":"UserPromptSubmit","session_id":"check-bridge","ppid":1,"cwd":"/tmp","matcher":null,"ts":0}'
OUT=$(printf '%s\n' "$SAMPLE" | "$BRIDGE" 2>/tmp/caff-bridge-stderr.$$) || {
    echo "ERROR: caff-bridge exited non-zero" >&2
    rm -f /tmp/caff-bridge-stderr.$$
    exit 1
}
ERR=$(cat /tmp/caff-bridge-stderr.$$)
rm -f /tmp/caff-bridge-stderr.$$
if [ -n "$OUT" ] || [ -n "$ERR" ]; then
    echo "ERROR: caff-bridge wrote to stdout/stderr (must be silent):" >&2
    [ -n "$OUT" ] && echo "stdout: $OUT" >&2
    [ -n "$ERR" ] && echo "stderr: $ERR" >&2
    exit 1
fi
echo "    OK: exit 0, no output"

echo "==> check-bridge: all checks passed"
