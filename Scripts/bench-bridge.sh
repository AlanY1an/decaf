#!/bin/bash
# bench-bridge.sh — decaf-bridge wall-clock budget benchmark (plan 02 §1.3/§5).
#
# Loops N invocations of decaf-bridge against a LIVE UNIX-socket listener with a
# realistic UserPromptSubmit payload on stdin, times each run with
# /usr/bin/time, and prints p50/p99. Fails when p99 breaches the <100 ms hard
# budget. This is the local acceptance gate the assembly pipeline uses — the
# budget is deliberately NOT checked in CI (runner jitter, plan 06 §5).
#
# Along the way it also enforces the silence contract on every iteration:
# exit code 0, empty stdout, empty stderr (plan 02 §1.3 rule 6).
#
# Usage: bench-bridge.sh [path-to-decaf-bridge] [iterations]
#   Without a path, builds the release binary from Core/ first.
#   Iterations default to 200.

set -euo pipefail

cd "$(dirname "$0")/.."

ITERATIONS="${2:-200}"
BUDGET_MS=100

BRIDGE="${1:-}"
if [ -z "$BRIDGE" ]; then
    echo "==> Building decaf-bridge (release)"
    swift build -c release --package-path Core --scratch-path Core/.build-bench \
        --product decaf-bridge
    BRIDGE="Core/.build-bench/release/decaf-bridge"
fi
if [ ! -x "$BRIDGE" ]; then
    echo "ERROR: decaf-bridge binary not found at: $BRIDGE" >&2
    exit 1
fi
if ! command -v python3 >/dev/null; then
    echo "ERROR: python3 is required for the drain listener" >&2
    exit 1
fi

# Short workdir: the socket path must stay far below sun_path's 104-byte cap.
WORKDIR=$(mktemp -d /tmp/decafbench.XXXXXX)
SOCK="$WORKDIR/agent.sock"
LISTENER_PID=""
cleanup() {
    if [ -n "$LISTENER_PID" ]; then
        kill "$LISTENER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Starting drain listener on $SOCK"
python3 - "$SOCK" <<'PY' &
import socket
import sys

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(128)
while True:
    connection, _ = server.accept()
    try:
        while connection.recv(4096):
            pass
    except OSError:
        pass
    connection.close()
PY
LISTENER_PID=$!
disown "$LISTENER_PID" 2>/dev/null || true # no job-control notice on cleanup kill

for _ in $(seq 1 50); do
    [ -S "$SOCK" ] && break
    sleep 0.1
done
if [ ! -S "$SOCK" ]; then
    echo "ERROR: drain listener did not come up" >&2
    exit 1
fi

# Realistic UserPromptSubmit stdin (field names match the recorded fixtures in
# Core/Tests/DecafCoreTests/Fixtures/).
PAYLOAD='{"session_id":"bench-0000","transcript_path":"/tmp/bench/t.jsonl","cwd":"/tmp/bench","prompt_id":"p-1","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"bench"}'
export DECAF_BRIDGE_SOCKET="$SOCK"

echo "==> Warm-up (3 unmeasured runs)"
for _ in 1 2 3; do
    if ! printf '%s' "$PAYLOAD" | "$BRIDGE"; then
        echo "ERROR: warm-up run exited non-zero" >&2
        exit 1
    fi
done

echo "==> Timing $ITERATIONS invocations"
TIMES="$WORKDIR/times.txt"
: > "$TIMES"
for i in $(seq 1 "$ITERATIONS"); do
    if ! printf '%s' "$PAYLOAD" | /usr/bin/time -p "$BRIDGE" \
            > "$WORKDIR/out.txt" 2> "$WORKDIR/timing.txt"; then
        echo "ERROR: decaf-bridge exited non-zero on iteration $i" >&2
        exit 1
    fi
    if [ -s "$WORKDIR/out.txt" ]; then
        echo "ERROR: decaf-bridge wrote to stdout on iteration $i (must be silent)" >&2
        exit 1
    fi
    # stderr must contain exactly /usr/bin/time's own three lines — anything
    # else came from the bridge, which the contract forbids.
    if grep -vqE '^(real|user|sys)[[:space:]]' "$WORKDIR/timing.txt"; then
        echo "ERROR: decaf-bridge wrote to stderr on iteration $i (must be silent):" >&2
        grep -vE '^(real|user|sys)[[:space:]]' "$WORKDIR/timing.txt" >&2
        exit 1
    fi
    awk '/^real/ { print $2 }' "$WORKDIR/timing.txt" >> "$TIMES"
done

COUNT=$(wc -l < "$TIMES" | tr -d ' ')
if [ "$COUNT" -ne "$ITERATIONS" ]; then
    echo "ERROR: expected $ITERATIONS timing samples, got $COUNT" >&2
    exit 1
fi

sort -n "$TIMES" > "$WORKDIR/sorted.txt"

# percentile_ms <p>: nearest-rank percentile (ceil(count * p / 100)), in ms.
percentile_ms() {
    local rank
    rank=$(( (COUNT * $1 + 99) / 100 ))
    [ "$rank" -lt 1 ] && rank=1
    awk -v r="$rank" 'NR == r { printf "%.0f", $1 * 1000 }' "$WORKDIR/sorted.txt"
}

P50_MS=$(percentile_ms 50)
P99_MS=$(percentile_ms 99)

# /usr/bin/time -p reports 2-decimal seconds → 10 ms resolution; a 0 reads
# as "under 10 ms", which is decisively inside the 100 ms budget.
display_ms() {
    if [ "$1" -eq 0 ]; then echo "<10"; else echo "$1"; fi
}

echo
echo "decaf-bridge wall clock over $ITERATIONS runs (live socket, 10 ms resolution):"
echo "    p50: $(display_ms "$P50_MS") ms"
echo "    p99: $(display_ms "$P99_MS") ms"

if [ "$P99_MS" -ge "$BUDGET_MS" ]; then
    echo "FAIL: p99 ${P99_MS} ms breaches the <${BUDGET_MS} ms hard budget (plan 02 §1.3)" >&2
    exit 1
fi
echo "PASS: p99 within the <${BUDGET_MS} ms budget"
