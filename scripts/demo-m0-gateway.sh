#!/usr/bin/env bash
# demo-m0-gateway.sh — Prove the FULL M0 auth chain: client→gateway→world.
#
# Two clients log in via the gateway (WebSocket :9001), receive JWTs + world
# address, connect directly to world (:9200) with those tokens, and see each
# other move. This exercises the complete chain (no JWT seeding, no bypass).
# This harness explicitly enables dev auth (password "dev"); the gateway issues real signed
# JWTs that the world validates via master.
#
# Usage: ./scripts/demo-m0-gateway.sh
# Exit: 0 = PASS, 1 = FAIL
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

export AVALON_AUTH_MODE=dev

GODOT="org.godotengine.Godot"
WORLD_DIR="$PROJECT_DIR/server/world"
A_LOG="/tmp/demo-gw-a.log"
B_LOG="/tmp/demo-gw-b.log"

log() { echo "[demo-m0-gateway] $*"; }

# ── Pre-flight: servers running? ──────────────────────────────
_started_servers=false
servers_up() {
  ss -tlnp 2>/dev/null | grep -q ":9001" && \
  ss -tlnp 2>/dev/null | grep -q ":9100" && \
  ss -ulnp 2>/dev/null | grep -q ":9200"
}
if servers_up; then
  log "Using existing servers"
else
  log "Starting servers..."
  AVALON_AUTH_MODE=dev bash scripts/dev-up.sh >/dev/null 2>&1
  _started_servers=true
  sleep 4
fi
if ! servers_up; then
  log "FATAL: servers not ready on 9001/9100/9200"
  [[ "$_started_servers" == "true" ]] && bash scripts/dev-down.sh >/dev/null 2>&1
  exit 1
fi
log "Servers ready (9001 gateway, 9100 master, 9200 world)"

# ── Launch two gateway clients ────────────────────────────────
log "Launching two clients via gateway login..."
run_gw_client() {
  local user="$1" seed="$2" out="$3"
  flatpak run \
    --env="AVALON_USE_GATEWAY=1" \
    --env="AVALON_GATEWAY_HOST=127.0.0.1" \
    --env="AVALON_USERNAME=$user" \
    --env="AVALON_PASSWORD=dev" \
    --env="AVALON_MOVE_DURATION=3.0" \
    --env="AVALON_MOVE_SPEED=50.0" \
    --env="AVALON_MOVE_SEED=$seed" \
    --filesystem="$PROJECT_DIR" --filesystem=/tmp \
    "$GODOT" --headless --path "$WORLD_DIR" \
    --scene res://tests/test_client.tscn > "$out" 2>&1
}
run_gw_client "player_a" 42 "$A_LOG" &
PID_A=$!
sleep 0.5
run_gw_client "player_b" 99 "$B_LOG" &
PID_B=$!
wait $PID_A; wait $PID_B

# ── Verify ────────────────────────────────────────────────────
RESULT_A=$(grep "result:" "$A_LOG" | tail -1 | sed 's/.*result: //')
RESULT_B=$(grep "result:" "$B_LOG" | tail -1 | sed 's/.*result: //')

pass_of() { echo "$1" | grep -q '"pass":true' && echo true || echo false; }
peers_of() { echo "$1" | grep -oE '"other_peers_seen":\[[^]]*\]'; }
login_of() { grep -q "login_ok" "$1" && echo "login_ok" || echo "NO-LOGIN"; }

PASS_A=$(pass_of "$RESULT_A"); PASS_B=$(pass_of "$RESULT_B")
log "Client A: gateway=$(login_of "$A_LOG"), pass=$PASS_A, $(peers_of "$RESULT_A")"
log "Client B: gateway=$(login_of "$B_LOG"), pass=$PASS_B, $(peers_of "$RESULT_B")"
log ""

# ── Cleanup ───────────────────────────────────────────────────
if [[ "$_started_servers" == "true" ]]; then
  log "Stopping servers..."
  bash scripts/dev-down.sh >/dev/null 2>&1
fi

if [[ "$PASS_A" == "true" && "$PASS_B" == "true" ]]; then
  log "M0 auth chain: client→gateway→world PASS"
  log "Both clients logged in via gateway, connected to world, saw each other move."
  exit 0
else
  log "FAILURE — full auth chain did not complete"
  log "Client A: $RESULT_A"
  log "Client B: $RESULT_B"
  log "M0 auth chain: FAIL"
  exit 1
fi
