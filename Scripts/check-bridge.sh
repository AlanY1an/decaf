#!/bin/bash
# check-bridge.sh — caff-bridge dependency-discipline gate (plan 06 §2/§5, review decision R4).
#
# Verifies, for a built caff-bridge binary:
#   1. otool -L linked libraries are ONLY system libraries (/usr/lib, /System).
#   2. Binary size < 2 MB.
#   3. Smoke A: a real hook event reaches a throwaway socket as a valid wire
#      frame, with empty stdout/stderr and exit 0.
#   4. Smoke B: with no listener at all, still exit 0 and still silent
#      (the graceful-degradation contract, plan 02 §1.3 rule 6).
#
# The smoke always runs against a socket in a temp directory, via
# CAFF_BRIDGE_SOCKET. It must never use the default path: that is the LIVE app's
# ~/Library/Application Support/Caffeinate/agent.sock, and a smoke event sent
# there registers a phantom working session in the running app. That session's
# ppid is this script, and once the script exits the sweep reclaims it — but
# until then the user's Mac is held awake by a test.
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

# Short workdir: the socket path must stay far below sun_path's 104-byte cap
# (same constraint as bench-bridge.sh).
WORKDIR=$(mktemp -d /tmp/caffcheck.XXXXXX)
LISTENER_PID=""
cleanup() {
    if [ -n "$LISTENER_PID" ]; then
        kill "$LISTENER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# This is the CLAUDE HOOK stdin shape (session_id / hook_event_name / cwd), which
# is what the bridge parses — not the WireEvent shape it emits. Sending it the
# wire shape makes the parse fail, and because every failure exits 0 silently the
# smoke would pass while proving nothing at all. Field names match the recorded
# fixtures in Core/Tests/CaffeinateCoreTests/Fixtures/ and bench-bridge.sh.
SAMPLE='{"session_id":"check-bridge","transcript_path":"/tmp/check/t.jsonl","cwd":"/tmp/check","prompt_id":"p-1","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"check"}'

run_bridge() { # run_bridge <socket-path>; sets OUT/ERR/RC
    set +e
    OUT=$(printf '%s\n' "$SAMPLE" \
        | CAFF_BRIDGE_SOCKET="$1" "$BRIDGE" 2>"$WORKDIR/stderr.txt")
    RC=$?
    set -e
    ERR=$(cat "$WORKDIR/stderr.txt")
}

assert_silent_success() { # assert_silent_success <label>
    if [ "$RC" -ne 0 ]; then
        echo "ERROR: caff-bridge exited $RC ($1); the contract is always exit 0" >&2
        exit 1
    fi
    if [ -n "$OUT" ] || [ -n "$ERR" ]; then
        echo "ERROR: caff-bridge wrote to stdout/stderr ($1) — it must be silent:" >&2
        [ -n "$OUT" ] && echo "stdout: $OUT" >&2
        [ -n "$ERR" ] && echo "stderr: $ERR" >&2
        exit 1
    fi
}

echo "==> Smoke A: hook event must arrive on the socket as a wire frame"
if command -v python3 >/dev/null 2>&1; then
    SOCK="$WORKDIR/agent.sock"
    RECEIVED="$WORKDIR/received.txt"
    python3 - "$SOCK" "$RECEIVED" <<'PY' &
import socket
import sys

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(8)
server.settimeout(10)
payload = b""
try:
    connection, _ = server.accept()
    while True:
        chunk = connection.recv(4096)
        if not chunk:
            break
        payload += chunk
    connection.close()
except OSError:
    pass
with open(sys.argv[2], "wb") as handle:
    handle.write(payload)
PY
    LISTENER_PID=$!

    for _ in $(seq 1 50); do
        [ -S "$SOCK" ] && break
        sleep 0.1
    done
    if [ ! -S "$SOCK" ]; then
        echo "ERROR: the test listener never came up at $SOCK" >&2
        exit 1
    fi

    run_bridge "$SOCK"
    assert_silent_success "live socket"

    wait "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""

    FRAME=$(cat "$RECEIVED" 2>/dev/null || true)
    if [ -z "$FRAME" ]; then
        echo "ERROR: nothing arrived on the socket." >&2
        echo "The bridge exited 0 silently, which it also does on a parse failure," >&2
        echo "so this means the sample payload never became a wire frame." >&2
        exit 1
    fi
    # Spot-check the fields the app keys on, so a silently-renamed field in the
    # wire protocol fails here rather than in the running app.
    for field in '"v":1' '"agent":"claude"' '"event":"UserPromptSubmit"' '"session_id":"check-bridge"'; do
        case "$FRAME" in
            *"$field"*) ;;
            *)
                echo "ERROR: the delivered frame is missing $field" >&2
                echo "frame: $FRAME" >&2
                exit 1
                ;;
        esac
    done
    echo "    OK: exit 0, silent, and a valid frame arrived"
else
    echo "    SKIP: python3 not available for the listener"
fi

echo "==> Smoke B: no listener must still exit 0, silently"
run_bridge "$WORKDIR/definitely-absent.sock"
assert_silent_success "no listener"
echo "    OK: exit 0, no output"

echo "==> check-bridge: all checks passed"
