#!/usr/bin/env bash
# T-029: LAN latency measurement script
#
# Runs the test client in latency mode against a live world server,
# collects 100 combat RTT samples, and reports min/p50/p95/p99/max.
#
# Prerequisites: world server running on port 9200 (use ./scripts/dev-up.sh)
# Usage: ./scripts/measure-latency.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RESULT_FILE="$PROJECT_DIR/docs/audits/m1-latency-result.json"
AUDIT_FILE="$PROJECT_DIR/docs/audits/m1-latency.md"
mkdir -p "$PROJECT_DIR/docs/audits"

# ── Load .env for secrets ───────────────────────────────────────────
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
    echo "[measure-latency] Loaded .env"
else
    echo "[measure-latency] WARNING: No .env found, using shell environment"
fi

# ── Check world server is running ───────────────────────────────────
if ! ss -ulnp 'sport = :9200' 2>/dev/null | grep -q 'godot'; then
    echo "[measure-latency] World server not running on port 9200"
    echo "[measure-latency] Start it first: ./scripts/dev-up.sh"
    exit 1
fi
echo "[measure-latency] World server detected on port 9200"

# ── Issue a signed JWT token (seeded in auth.sessions) ─────────────
TOKEN=$(python3 "$SCRIPT_DIR/issue-jwt.py" "latency_tester" 2>/dev/null)
if [[ -z "$TOKEN" || ${#TOKEN} -lt 50 ]]; then
    echo "[measure-latency] ERROR: JWT generation failed (token_len=${#TOKEN})"
    exit 1
fi
echo "[measure-latency] JWT issued and seeded for latency_tester"

# ── Resolve flatpak ─────────────────────────────────────────────────
GODOT_FLATPAK="org.godotengine.Godot"
FLATPAK_CMD="flatpak run \
    --env=AVALON_LATENCY_MODE=1 \
    --env=AVALON_HOST=127.0.0.1 \
    --env=AVALON_PORT=9200 \
    --env=AVALON_TOKEN="$TOKEN" \
    --env=AVALON_RESULT_FILE=$RESULT_FILE \
    --filesystem=/home/soundwave/avalon \
    --filesystem=/tmp \
    $GODOT_FLATPAK"

# ── Run latency measurement ─────────────────────────────────────────
echo "[measure-latency] Running 100 combat RTT samples..."
echo "=================================================="

eval $FLATPAK_CMD \
    --headless \
    --path "$PROJECT_DIR/server/world" \
    --scene res://tests/test_client.tscn 2>&1

CLIENT_EXIT=$?
echo "=================================================="
echo "[measure-latency] Client exited with code: $CLIENT_EXIT"

# ── Parse and display results ───────────────────────────────────────
if [[ -f "$RESULT_FILE" ]]; then
    echo ""
    echo "[measure-latency] === Latency Report ==="
    python3 - "$RESULT_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
print(f"Movement RTT (ping/pong): {r.get('ping_rtt_ms', -1):.2f} ms")
print(f"Combat RTT samples: {r.get('latency_samples', 0)}")
print(f"Combat RTT min:  {r.get('latency_min_ms', -1):.2f} ms")
print(f"Combat RTT p50:  {r.get('latency_p50_ms', -1):.2f} ms")
print(f"Combat RTT p95:  {r.get('latency_p95_ms', -1):.2f} ms")
print(f"Combat RTT p99:  {r.get('latency_p99_ms', -1):.2f} ms")
print(f"Combat RTT max:  {r.get('latency_max_ms', -1):.2f} ms")
print(f"Combat RTT avg:  {r.get('latency_avg_ms', -1):.2f} ms")
print(f"Verdict: {'PASS' if r.get('pass', False) else 'FAIL'}")
PYEOF
else
    echo "[measure-latency] WARNING: No result file at $RESULT_FILE"
fi

# ── Write audit markdown ────────────────────────────────────────────
if [[ -f "$RESULT_FILE" ]]; then
    python3 - "$RESULT_FILE" "$AUDIT_FILE" <<'PYEOF'
import json, datetime, sys
result_file, audit_file = sys.argv[1], sys.argv[2]
with open(result_file) as f:
    r = json.load(f)
ts = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with open(audit_file, 'w') as out:
    out.write('# M1 LAN Latency Audit\n\n')
    out.write(f'Date: {ts}\n\n')
    out.write('## Method\n')
    out.write('- Headless test client connected to world server via ENet\n')
    out.write('- Movement baseline: single ping/pong round-trip\n')
    out.write('- Combat RTT: 100 Strike ability intents sent with invalid target (-1)\n')
    out.write('- Server returns ability_rejected immediately (validation failure)\n')
    out.write('- Client-side microsecond timestamps measure round-trip time\n\n')
    out.write('## Results\n\n')
    out.write('| Metric | Value (ms) |\n')
    out.write('|--------|------------|\n')
    out.write(f'| Movement RTT (ping/pong) | {r.get("ping_rtt_ms", -1):.2f} |\n')
    out.write(f'| Combat samples collected | {r.get("latency_samples", 0)} |\n')
    out.write(f'| Combat RTT min | {r.get("latency_min_ms", -1):.2f} |\n')
    out.write(f'| Combat RTT p50 | {r.get("latency_p50_ms", -1):.2f} |\n')
    out.write(f'| Combat RTT p95 | {r.get("latency_p95_ms", -1):.2f} |\n')
    out.write(f'| Combat RTT p99 | {r.get("latency_p99_ms", -1):.2f} |\n')
    out.write(f'| Combat RTT max | {r.get("latency_max_ms", -1):.2f} |\n')
    out.write(f'| Combat RTT avg | {r.get("latency_avg_ms", -1):.2f} |\n\n')
    out.write('## Pass Criteria\n')
    out.write('- Movement RTT < 200ms\n')
    out.write('- Combat p95 RTT < 100ms\n\n')
    out.write(f'## Verdict: {"PASS" if r.get("pass", False) else "FAIL"}\n')
    if not r.get('pass', False):
        out.write('\n## Remediation\n')
        if r.get('ping_rtt_ms', 0) >= 200:
            out.write('- Movement RTT >= 200ms: Check network interface, firewall, ENet settings\n')
        if r.get('latency_p95_ms', 0) >= 100:
            out.write('- Combat p95 >= 100ms: Reduce server load, check ENet channel congestion\n')
print(f'Audit written to {audit_file}')
PYEOF
fi

exit $CLIENT_EXIT
