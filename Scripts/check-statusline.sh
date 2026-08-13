#!/bin/bash
# check-statusline.sh — decaf-statusline contract gate (plan 09 M2/M4).
#
# Verifies, for a built decaf-statusline binary:
#   1. otool -L linked libraries are ONLY system libraries (same R4 discipline
#      as decaf-bridge).
#   2. Smoke A: a statusline payload produces the default line, exit 0, and a
#      Statusline wire frame carrying the quota lands on a throwaway socket.
#   3. Smoke B: garbage stdin → empty output, empty stderr, exit 0.
#   4. Smoke C: chain passthrough — the sidecar's command runs, receives the
#      ORIGINAL stdin bytes, and its stdout is passed through verbatim.
#   5. Smoke D: a chain command that dies instantly (EPIPE on our stdin write)
#      still exits 0.
#
# Both overrides keep the smoke away from the live app: DECAF_BRIDGE_SOCKET
# for the frame (never the real agent.sock) and DECAF_STATUSLINE_APPSUPPORT
# for the chain sidecar (never the real App Support).
#
# Usage: check-statusline.sh [path-to-decaf-statusline]
#   Without an argument, builds the release binary from Core/ first.

set -euo pipefail

cd "$(dirname "$0")/.."

BIN="${1:-}"
if [ -z "$BIN" ]; then
    echo "==> Building decaf-statusline (release)"
    swift build -c release --package-path Core --product decaf-statusline
    BIN="Core/.build/release/decaf-statusline"
fi

if [ ! -x "$BIN" ]; then
    echo "ERROR: decaf-statusline binary not found at: $BIN" >&2
    exit 1
fi

echo "==> Checking linked libraries (otool -L whitelist)"
VIOLATIONS=$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' \
    | grep -vE '^(/usr/lib/|/System/)' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: decaf-statusline links non-system libraries:" >&2
    echo "$VIOLATIONS" >&2
    exit 1
fi
echo "    OK: system libraries only"

# Short workdir: socket paths must stay far below sun_path's 104-byte cap.
WORK=$(mktemp -d /tmp/dsl.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
SOCK="$WORK/s.sock"
APPSUPPORT="$WORK/appsupport"
mkdir -p "$APPSUPPORT"

PAYLOAD='{"session_id":"smoke","model":{"id":"claude-opus-4-5","display_name":"Opus 4.5"},"rate_limits":{"five_hour":{"used_percentage":34.2,"resets_at":"2026-08-07T12:00:00Z"},"seven_day":{"used_percentage":12.5,"resets_at":"2026-08-11T00:00:00Z"}}}'

run_statusline() { # run_statusline <stdin-text>; sets OUT/ERR/RC
    set +e
    OUT=$(printf '%s' "$1" \
        | DECAF_BRIDGE_SOCKET="$SOCK" DECAF_STATUSLINE_APPSUPPORT="$APPSUPPORT" "$BIN" \
        2>"$WORK/stderr")
    RC=$?
    set -e
    ERR=$(cat "$WORK/stderr")
}

echo "==> Smoke A: default line + quota frame on the socket"
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 required for the socket listener" >&2
    exit 1
fi
RECEIVED="$WORK/frame.json"
python3 - "$SOCK" "$RECEIVED" <<'PY' &
import socket, sys
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(1)
server.settimeout(5)
conn, _ = server.accept()
data = b""
while not data.endswith(b"\n"):
    chunk = conn.recv(4096)
    if not chunk:
        break
    data += chunk
open(sys.argv[2], "wb").write(data)
PY
LISTENER=$!
while [ ! -S "$SOCK" ]; do sleep 0.05; done

run_statusline "$PAYLOAD"
wait "$LISTENER"

[ "$RC" -eq 0 ] || { echo "ERROR: exit $RC (expected 0)" >&2; exit 1; }
[ -z "$ERR" ] || { echo "ERROR: stderr not empty: $ERR" >&2; exit 1; }
[ "$OUT" = "Opus 4.5 | 5h 34%" ] \
    || { echo "ERROR: default line was: $OUT" >&2; exit 1; }
python3 - "$RECEIVED" <<'PY'
import json, sys
frame = json.loads(open(sys.argv[1]).read())
assert frame["event"] == "Statusline", frame
assert frame["session_id"] == "smoke", frame
quota = frame["quota"]
assert quota["five_hour_used_pct"] == 34.2, quota
assert quota["seven_day_used_pct"] == 12.5, quota
assert quota["model_id"] == "claude-opus-4-5", quota
PY
echo "    OK: default line + valid Statusline frame"

echo "==> Smoke B: garbage stdin is silent success"
run_statusline "garbage"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] \
    || { echo "ERROR: garbage handling — rc=$RC out=$OUT err=$ERR" >&2; exit 1; }
echo "    OK: exit 0, no output"

echo "==> Smoke C: chain passthrough with original stdin"
cat > "$APPSUPPORT/statusline-chain.json" <<'EOF'
{"version":1,"previous":{"type":"command","command":"read line; printf 'chained:%s' \"$(printf '%s' \"$line\" | head -c 14)\""}}
EOF
run_statusline "$PAYLOAD"
[ "$RC" -eq 0 ] || { echo "ERROR: chain exit $RC" >&2; exit 1; }
[ "$OUT" = 'chained:{"session_id":' ] \
    || { echo "ERROR: chain output was: $OUT" >&2; exit 1; }
echo "    OK: chain ran with the original payload and its stdout passed through"

echo "==> Smoke D: instantly-dying chain (EPIPE) still exits 0"
cat > "$APPSUPPORT/statusline-chain.json" <<'EOF'
{"version":1,"previous":{"type":"command","command":"exit 0"}}
EOF
run_statusline "$PAYLOAD"
[ "$RC" -eq 0 ] || { echo "ERROR: EPIPE path exit $RC" >&2; exit 1; }
echo "    OK: exit 0"

echo "==> all checks passed"
