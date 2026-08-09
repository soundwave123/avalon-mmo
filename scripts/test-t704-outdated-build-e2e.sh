#!/usr/bin/env bash
# T-704 E2E — a rejected login must STOP and TELL THE PLAYER, over real transport.
#
# The bug: the world rejects a stale client with `outdated_build` and drops the peer; the client's
# recovery re-entered _setup_networking(), which re-read AVALON_TOKEN and reconnected instantly, so
# the world rejected it again — 514 rejection cycles / 1.09 MB of client-log spam in ~60 s, with
# nothing on screen. Unit tests can prove the decision table; only a real ENet handshake against a
# real world server can prove the STORM is gone, so this boots an ISOLATED world on :9240 with an
# unreachable minimum build and points a real client at it. It never touches :9200/:9100/:9001
# (the live stack) — the master is not needed at all here, because the build gate rejects BEFORE any
# token or DB work.
#
# PHASE 1 — terminal (outdated_build):
#   1. the world logs EXACTLY ONE rejection (bounded — pre-fix this ran into the hundreds);
#   2. the client's own log carries the player-facing remedy ("out of date … Download the latest");
#   3. no "Signal ... is already connected" spam (the T-704 signal-churn defect);
#   4. the client is still ALIVE at the end — it parked on the login form instead of quitting.
# PHASE 2 — transient (nothing listening): retries are capped and give up (attempts 1..5 then stop),
#   proving a dead server cannot produce an unbounded loop either.
#
# AVALON_RECOVERY_INTERACTIVE=1 is the seam that makes this runnable headlessly: a headless client
# normally fails fast (a harness has no player to inform), and the storm only ever existed on the
# player-facing path. Everything else here — transport, server, rejection, recovery logic — is real.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
export AVALON_GODOT_PIN="${AVALON_GODOT_PIN:-native-4.7}"
GODOT="$SCRIPT_DIR/godot-bin.sh"
LANE_PORT=9240
LANE_OPS_PORT=9246
DEAD_PORT=9247          # deliberately nothing listening: the transient/backoff case
OUT_DIR="${AVALON_TEST_LOG_DIR:-/tmp/avalon-tests-t704}"
WORLD_LOG="$OUT_DIR/t704-world.log"
CLIENT_LOG="$OUT_DIR/t704-client-terminal.log"
RETRY_LOG="$OUT_DIR/t704-client-transient.log"
# A future stamp no build can ever satisfy => every client is "outdated" (T-514 gate is opt-in).
MIN_BUILD=2099-01-01T00:00:00Z
STALE_BUILD=2026-01-01T00:00:00Z
TERMINAL_SECS=25        # ~25 s was enough to log 200+ rejection cycles pre-fix
# 5 capped attempts = 1+2+4+8+16 s of backoff PLUS an ENet connect timeout (~30 s) per attempt; the
# poll below exits the moment the give-up lands, so this ceiling only bounds a genuine failure.
TRANSIENT_SECS=300
log() { echo "[t704-e2e] $*"; }

mkdir -p "$OUT_DIR"
cleanup() {
	[[ -n "${CLIENT_PID:-}" ]] && kill "$CLIENT_PID" 2>/dev/null
	[[ -n "${RETRY_PID:-}" ]] && kill "$RETRY_PID" 2>/dev/null
	[[ -n "${WORLD_PID:-}" ]] && kill "$WORLD_PID" 2>/dev/null
	pkill -f "AVALON_PORT=$LANE_PORT" 2>/dev/null
	return 0
}
trap cleanup EXIT

log "importing projects"
"$GODOT" --headless --path "$PROJECT_DIR/server/world" --import >/dev/null 2>&1
"$GODOT" --headless --path "$PROJECT_DIR/client" --import >/dev/null 2>&1

log "booting isolated world on :$LANE_PORT with AVALON_MIN_BUILD=$MIN_BUILD"
AVALON_PORT=$LANE_PORT "$GODOT" \
	--env="AVALON_PORT=$LANE_PORT" --env="AVALON_OPS_PORT=$LANE_OPS_PORT" \
	--env="AVALON_MIN_BUILD=$MIN_BUILD" --env="AVALON_SPAWN_FIXED=1" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/server/world" --scene res://scenes/main.tscn \
	>"$WORLD_LOG" 2>&1 &
WORLD_PID=$!
for _ in $(seq 1 40); do
	grep -q "listening on enet://0.0.0.0:$LANE_PORT" "$WORLD_LOG" 2>/dev/null && break
	sleep 1
done
grep -q "listening on enet://0.0.0.0:$LANE_PORT" "$WORLD_LOG" || {
	log "FATAL: lane world never bound :$LANE_PORT"; tail -20 "$WORLD_LOG"; exit 1; }
log "lane world up"

# ---------------------------------------------------------------- phase 1: terminal rejection
# The token is a throwaway string on purpose: the build gate refuses the handshake before the world
# looks at it, so this phase needs neither the master nor a seeded session.
log "phase 1: stale client ($STALE_BUILD) → :$LANE_PORT for ${TERMINAL_SECS}s"
"$GODOT" \
	--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=$LANE_PORT" \
	--env="AVALON_TOKEN=t704-e2e-throwaway-token" \
	--env="AVALON_CLIENT_BUILD=$STALE_BUILD" \
	--env="AVALON_RECOVERY_INTERACTIVE=1" \
	--env="AVALON_OBSERVE=1" --env="AVALON_OBSERVE_SECS=600" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/client" --scene res://scenes/main.tscn \
	>"$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!
sleep "$TERMINAL_SECS"

RC1=0
REJECTS=$(grep -c "rejected peer_id=.*outdated_build" "$WORLD_LOG" 2>/dev/null)
CONNECTS=$(grep -c "\[world\] peer connected" "$WORLD_LOG" 2>/dev/null)
SIGSPAM=$(grep -c "is already connected to given callable" "$CLIENT_LOG" 2>/dev/null)
log "world: $CONNECTS peer connects, $REJECTS outdated_build rejections in ${TERMINAL_SECS}s"
[[ "$REJECTS" -eq 1 ]] || { log "FAIL 1: expected exactly 1 rejection, got $REJECTS (storm)"; RC1=1; }
[[ "$CONNECTS" -le 2 ]] || { log "FAIL 1: $CONNECTS connection attempts — client is storming"; RC1=1; }
grep -q "\[login\] notice shown: .*out of date" "$CLIENT_LOG" || {
	log "FAIL 1: the login form never rendered the update remedy"; RC1=1; }
grep -q "disconnect terminal" "$CLIENT_LOG" || { log "FAIL 1: rejection not classified terminal"; RC1=1; }
[[ "$SIGSPAM" -eq 0 ]] || { log "FAIL 1: $SIGSPAM 'already connected' signal errors"; RC1=1; }
kill -0 "$CLIENT_PID" 2>/dev/null || { log "FAIL 1: client died instead of parking on the login form"; RC1=1; }
[[ $RC1 -eq 0 ]] && log "phase 1 PASS — one rejection, remedy shown, client parked, zero signal spam"
kill "$CLIENT_PID" 2>/dev/null; CLIENT_PID=""

# ---------------------------------------------------------------- phase 2: transient retry cap
log "phase 2: client → dead :$DEAD_PORT, expecting capped retries for up to ${TRANSIENT_SECS}s"
"$GODOT" \
	--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=$DEAD_PORT" \
	--env="AVALON_TOKEN=t704-e2e-throwaway-token" \
	--env="AVALON_RECOVERY_INTERACTIVE=1" \
	--env="AVALON_OBSERVE=1" --env="AVALON_OBSERVE_SECS=600" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/client" --scene res://scenes/main.tscn \
	>"$RETRY_LOG" 2>&1 &
RETRY_PID=$!
for _ in $(seq 1 "$TRANSIENT_SECS"); do
	grep -q "Gave up after" "$RETRY_LOG" 2>/dev/null && break
	sleep 1
done
RC2=0
ATTEMPTS=$(grep -c "disconnect retry" "$RETRY_LOG" 2>/dev/null)
log "phase 2: $ATTEMPTS retry attempts logged"
grep -q "Gave up after" "$RETRY_LOG" || { log "FAIL 2: never gave up — unbounded retry"; RC2=1; }
[[ "$ATTEMPTS" -le 5 ]] || { log "FAIL 2: $ATTEMPTS attempts exceeds the cap of 5"; RC2=1; }
grep -q "attempt 1 of 5" "$RETRY_LOG" || { log "FAIL 2: no visible per-attempt status"; RC2=1; }
sleep 5  # nothing may resume after the give-up
AFTER=$(grep -c "disconnect retry" "$RETRY_LOG" 2>/dev/null)
[[ "$AFTER" -eq "$ATTEMPTS" ]] || { log "FAIL 2: retries resumed after give-up ($AFTER)"; RC2=1; }
[[ $RC2 -eq 0 ]] && log "phase 2 PASS — $ATTEMPTS capped attempts, then a permanent stop"

RC=$(( RC1 + RC2 ))
if [[ $RC -ne 0 ]]; then
	log "--- world log (rejections) ---"; grep "rejected peer_id" "$WORLD_LOG" | tail -10
	log "--- terminal client log ---"; grep -E "\[client\]" "$CLIENT_LOG" | tail -15
	log "--- transient client log ---"; grep -E "\[client\]" "$RETRY_LOG" | tail -15
fi
[[ $RC -eq 0 ]] && log "PASS" || log "FAIL (rc=$RC)"
exit $RC
