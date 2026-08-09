#!/usr/bin/env bash
# Integration test: JWT refresh token rotation (T-007).
#
# Proves the full refresh flow end-to-end:
#   1. Gateway boots with both secrets (boot-refusal without)
#   2. Login returns access_token + refresh_token
#   3. Refresh token rotation: new tokens, old refresh consumed
#   4. Replayed old refresh token -> refresh_err (401)
#   5. New refresh token works after rotation
#   6. Negative: gateway boot-refusal without refresh secret
#
# Uses websocat for WebSocket frames against gateway (WS port 9001).
# SessionManager runs in-memory, no Postgres needed.
#
# Usage: ./scripts/test_refresh_flow.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATEWAY_DIR="$PROJECT_DIR/server/gateway"
WORK_DIR="/tmp/avalon_refresh_smoke_$$"
mkdir -p "$WORK_DIR"

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
fi

# Route through the repository resolver so --env reaches either Flatpak 4.6 or native 4.7.
GODOT="$SCRIPT_DIR/godot-bin.sh"

if ! command -v websocat >/dev/null 2>&1; then
    echo "[refresh] FATAL - websocat not found"
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[refresh] FATAL - jq not found"
    exit 2
fi

# Gateway WS port (from server/gateway/scripts/server_config.gd)
PORT=9001

# JWT secrets (32+ bytes each, required by gateway boot check)
# Use 41-char raw strings. A length divisible by four is intentionally interpreted as base64 by
# JwtUtil; the historical 40-char fixtures decoded to only 30 bytes and failed the 32-byte guard.
export AVALON_JWT_SECRET="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export AVALON_JWT_REFRESH_SECRET="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
export AVALON_JWT_TTL_SECONDS="1"
export AVALON_AUTH_MODE="dev"

GATEWAY_PID=""

cleanup() {
    if [[ -n "$GATEWAY_PID" ]] && kill -0 "$GATEWAY_PID" 2>/dev/null; then
        kill "$GATEWAY_PID" 2>/dev/null || true
        wait "$GATEWAY_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PASS=0
FAIL=0

pass() { echo "[refresh] PASS: $1"; ((PASS++)) || true; }
fail() { echo "[refresh] FAIL: $1"; ((FAIL++)) || true; }

kill_stale() {
    local target_port="$1"
    STALE_PIDS=$(ss -ulnp "sport = :$target_port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    if [[ -n "$STALE_PIDS" ]]; then
        echo "[refresh] Killing stale process(es) on port $target_port: $STALE_PIDS"
        for spid in $STALE_PIDS; do
            kill "$spid" 2>/dev/null || true
        done
        sleep 1
        if ss -ulnp "sport = :$target_port" 2>/dev/null | grep -q "godot"; then
            echo "[refresh] FATAL - port $target_port still occupied after kill"
            exit 1
        fi
    fi
}

start_gateway() {
    local log_tag="$1"
    local log_file="$WORK_DIR/gateway_${log_tag}.log"

    kill_stale "$PORT"

    "$GODOT" --headless --path "$GATEWAY_DIR" --import >/dev/null 2>&1

    "$GODOT" \
        --env="AVALON_JWT_SECRET=$AVALON_JWT_SECRET" \
        --env="AVALON_JWT_REFRESH_SECRET=$AVALON_JWT_REFRESH_SECRET" \
        --env="AVALON_JWT_TTL_SECONDS=$AVALON_JWT_TTL_SECONDS" \
        --env="AVALON_AUTH_MODE=$AVALON_AUTH_MODE" \
        --env="AVALON_PG_PASSWORD=${AVALON_PG_PASSWORD:-}" \
        --headless \
        --path "$GATEWAY_DIR" \
        --scene res://scenes/main.tscn \
        > "$log_file" 2>&1 &
    GATEWAY_PID=$!
    echo "[refresh] Gateway PID: $GATEWAY_PID"

    READY=0
    for i in $(seq 1 40); do
        sleep 0.5
        if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
            echo "[refresh] Gateway (PID $GATEWAY_PID) exited prematurely"
            cat "$log_file"
            return 1
        fi
        if grep -qF "listening on ws://0.0.0.0:$PORT" "$log_file" 2>/dev/null; then
            READY=1
            break
        fi
    done

    if [[ $READY -ne 1 ]]; then
        echo "[refresh] Gateway failed to start within 20s"
        cat "$log_file"
        return 1
    fi

    echo "[refresh] Gateway ready on ws://0.0.0.0:$PORT"
    return 0
}

ws_send() {
    local message="$1"
    local output_file="$2"
    printf '%s\n' "$message" | websocat -t -1 "ws://127.0.0.1:$PORT" > "$output_file" 2>/dev/null || true
}

# ============================================================
# TEST 1: Gateway boots with both secrets set
# ============================================================
echo ""
echo "=== TEST 1: Gateway boots with both secrets ==="
GATEWAY_PID=""
if start_gateway "t1"; then
    pass "gateway booted with both secrets"
else
    fail "gateway failed to boot with both secrets"
    echo "[refresh] ABORT: cannot proceed"
    exit 1
fi

# ============================================================
# TEST 2: Login returns access_token + refresh_token
# ============================================================
echo ""
echo "=== TEST 2: Login returns access + refresh tokens ==="

LOGIN_MSG='{"type":"login","username":"alice","password":"dev"}'
ws_send "$LOGIN_MSG" "$WORK_DIR/login_resp.json"
LOGIN_RESP=$(cat "$WORK_DIR/login_resp.json")
LOGIN_TYPE=$(echo "$LOGIN_RESP" | jq -r '.type // empty' 2>/dev/null || true)

if [[ "$LOGIN_TYPE" != "login_ok" ]]; then
    fail "login did not return login_ok (got: $LOGIN_TYPE)"
    echo "  Response: $LOGIN_RESP"
    exit 1
fi

ACCESS_TOKEN=$(echo "$LOGIN_RESP" | jq -r '.access_token // empty' 2>/dev/null || true)
REFRESH_TOKEN=$(echo "$LOGIN_RESP" | jq -r '.refresh_token // empty' 2>/dev/null || true)

if [[ -z "$ACCESS_TOKEN" ]]; then
    fail "login response missing access_token"
    exit 1
fi
if [[ -z "$REFRESH_TOKEN" ]]; then
    fail "login response missing refresh_token"
    exit 1
fi

TOKEN_PARTS=$(echo "$ACCESS_TOKEN" | tr '.' '\n' | wc -l)
if [[ "$TOKEN_PARTS" -ne 3 ]]; then
    fail "access_token does not have 3 JWT parts (has $TOKEN_PARTS)"
    exit 1
fi

pass "login returned access_token + refresh_token with valid JWT structure"

# ============================================================
# TEST 3: Refresh token rotation (valid -> new tokens)
# ============================================================
echo ""
echo "=== TEST 3: Valid refresh token -> new token pair ==="

sleep 2  # let 1s TTL access token expire

REFRESH_MSG="{\"type\":\"refresh\",\"refresh_token\":\"$REFRESH_TOKEN\"}"
ws_send "$REFRESH_MSG" "$WORK_DIR/refresh_resp.json"
REFRESH_RESP=$(cat "$WORK_DIR/refresh_resp.json")
REFRESH_TYPE=$(echo "$REFRESH_RESP" | jq -r '.type // empty' 2>/dev/null || true)

if [[ "$REFRESH_TYPE" != "refresh_ok" ]]; then
    fail "refresh did not return refresh_ok (got: $REFRESH_TYPE)"
    echo "  Response: $REFRESH_RESP"
    exit 1
fi

NEW_ACCESS=$(echo "$REFRESH_RESP" | jq -r '.access_token // empty' 2>/dev/null || true)
NEW_REFRESH=$(echo "$REFRESH_RESP" | jq -r '.refresh_token // empty' 2>/dev/null || true)

if [[ -z "$NEW_ACCESS" ]]; then
    fail "refresh response missing new access_token"
    exit 1
fi
if [[ -z "$NEW_REFRESH" ]]; then
    fail "refresh response missing new refresh_token"
    exit 1
fi
if [[ "$NEW_REFRESH" == "$REFRESH_TOKEN" ]]; then
    fail "refresh returned SAME refresh token (rotation failed)"
    exit 1
fi
pass "refresh returned new token pair (old refresh consumed)"

# ============================================================
# TEST 4: Replay old refresh token -> refresh_err
# ============================================================
echo ""
echo "=== TEST 4: Replay old refresh token -> refresh_err ==="

ws_send "$REFRESH_MSG" "$WORK_DIR/replay_resp.json"
REPLAY_RESP=$(cat "$WORK_DIR/replay_resp.json")
REPLAY_TYPE=$(echo "$REPLAY_RESP" | jq -r '.type // empty' 2>/dev/null || true)
REPLAY_REASON=$(echo "$REPLAY_RESP" | jq -r '.reason // empty' 2>/dev/null || true)

if [[ "$REPLAY_TYPE" != "refresh_err" ]]; then
    fail "replay did not return refresh_err (got: $REPLAY_TYPE)"
    echo "  Response: $REPLAY_RESP"
    exit 1
fi
if [[ "$REPLAY_REASON" != "refresh_token_consumed" ]]; then
    fail "replay reason wrong (got: $REPLAY_REASON, expected: refresh_token_consumed)"
    exit 1
fi
pass "replayed refresh token rejected with refresh_token_consumed"

# ============================================================
# TEST 5: New refresh token works, old still dead
# ============================================================
echo ""
echo "=== TEST 5: New refresh works, old still dead ==="

NEW_REFRESH_MSG="{\"type\":\"refresh\",\"refresh_token\":\"$NEW_REFRESH\"}"
ws_send "$NEW_REFRESH_MSG" "$WORK_DIR/refresh2_resp.json"
REFRESH2_RESP=$(cat "$WORK_DIR/refresh2_resp.json")
REFRESH2_TYPE=$(echo "$REFRESH2_RESP" | jq -r '.type // empty' 2>/dev/null || true)

if [[ "$REFRESH2_TYPE" != "refresh_ok" ]]; then
    fail "new refresh token did not work (got: $REFRESH2_TYPE)"
    echo "  Response: $REFRESH2_RESP"
    exit 1
fi
pass "new refresh token successfully rotated"

ws_send "$REFRESH_MSG" "$WORK_DIR/old_still_dead.json"
OLD_RESP=$(cat "$WORK_DIR/old_still_dead.json")
OLD_TYPE=$(echo "$OLD_RESP" | jq -r '.type // empty' 2>/dev/null || true)

if [[ "$OLD_TYPE" != "refresh_err" ]]; then
    fail "old token should still be dead (got: $OLD_TYPE)"
    exit 1
fi
pass "old refresh token still rejected after new token used"

# ============================================================
# TEST 6: Gateway refuses boot without refresh secret
# ============================================================
echo ""
echo "=== TEST 6: Gateway refuses boot without refresh secret ==="

kill "$GATEWAY_PID" 2>/dev/null || true
wait "$GATEWAY_PID" 2>/dev/null || true
GATEWAY_PID=""
sleep 2
kill_stale "$PORT"

NEG_LOG="$WORK_DIR/gateway_neg.log"
"$GODOT" --headless --path "$GATEWAY_DIR" --import >/dev/null 2>&1

"$GODOT" \
    --env="AVALON_JWT_SECRET=$AVALON_JWT_SECRET" \
    --env="AVALON_JWT_REFRESH_SECRET=" \
    --env="AVALON_AUTH_MODE=$AVALON_AUTH_MODE" \
    --headless \
    --path "$GATEWAY_DIR" \
    --scene res://scenes/main.tscn \
    > "$NEG_LOG" 2>&1 &
NEG_PID=$!

BOOTTED=0
for i in $(seq 1 20); do
    sleep 0.5
    if ! kill -0 "$NEG_PID" 2>/dev/null; then
        if grep -qiE "(FATAL|refusing to start|missing|too short)" "$NEG_LOG" 2>/dev/null; then
            BOOTTED=2
        else
            BOOTTED=3
        fi
        break
    fi
    if grep -qF "listening on ws://0.0.0.0:$PORT" "$NEG_LOG" 2>/dev/null; then
        BOOTTED=1
        break
    fi
done

if kill -0 "$NEG_PID" 2>/dev/null; then
    kill "$NEG_PID" 2>/dev/null || true
    wait "$NEG_PID" 2>/dev/null || true
fi

if [[ $BOOTTED -eq 2 ]]; then
    pass "gateway refused to boot without refresh secret"
elif [[ $BOOTTED -eq 1 ]]; then
    fail "gateway booted WITHOUT refresh secret (should have refused)"
    tail -10 "$NEG_LOG"
else
    if grep -qiE "(FATAL|refusing|missing|too short)" "$NEG_LOG" 2>/dev/null; then
        pass "gateway refused to boot without refresh secret"
    else
        fail "gateway exited without boot refusal message"
        tail -10 "$NEG_LOG"
    fi
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================="
echo "[refresh] Results: $PASS passed, $FAIL failed"
echo "========================================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

exit 0
