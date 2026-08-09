#!/usr/bin/env bash
# T-729 two-fight E2E: auto-attack is a STICKY MODE — one toggle press covers BOTH fights.
#
# Boots an ISOLATED world from THIS worktree on :9230 → the LIVE master (:9100), then drives ONE
# real piloted client (client/scripts/main.gd, so the T-057/T-729 autoattack code is live) through
# two consecutive engagements. It never touches the shared :9200 stack.
#
# Arena: the training ring at spawn — Training Dummy (100 HP, `dummy`, never fights back) at
# (10,10) and Straw Sparring Effigy (200 HP, `non_lethal`, cannot kill a trainee) at (16,10), 6 m
# apart. Zero death risk, and BOTH are broadcast `hostile:false` — which also proves T-729 gates
# swings on ALIVE, not on the T-665 disposition flag (gating on disposition would silently stop
# auto-attack from ever hitting a practice target).
#
# The assertions ride the T-721 press ledger in observe().ability.counts:
#   result:1              — a landed auto-swing (ability 1 = Strike)
#   rejected:*:1          — a REFUSED auto-swing; "target_is_dead" is the corpse-hammering bug
# PASS needs all four:
#   1. fight 1 lands swings after exactly ONE ` press;
#   2. once the dummy dies, swings stop dead — no further result:1 AND no target_is_dead reject
#      (the T-721 follow-up: the old timer hammered the corpse until respawn);
#   3. the mode is still armed — selecting the effigy needs NO second ` press;
#   4. fight 2 lands swings.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
export AVALON_GODOT_PIN="${AVALON_GODOT_PIN:-native-4.7}"
GODOT="$SCRIPT_DIR/godot-bin.sh"
LANE_PORT=9230
LANE_OPS_PORT=9236
USER_NAME=t729pilot
PILOT_DIR=/tmp/avalon-pilot-t729
WORLD_LOG=/tmp/t729-lane-world.log
log() { echo "[t729-e2e] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1" >/dev/null 2>&1; }

ss -ltn 2>/dev/null | grep -q ":9100" || { log "FATAL: live master not on :9100"; exit 1; }
[[ -f "$PROJECT_DIR/.env" ]] && { set -a; source "$PROJECT_DIR/.env"; set +a; }
# A lane worktree has no .env of its own — fall back to the checkout that does (T-699 lane idiom).
[[ -z "${AVALON_JWT_SECRET:-}" && -f /home/soundwave/avalon/.env ]] && {
	set -a; source /home/soundwave/avalon/.env; set +a; }
[[ -z "${AVALON_JWT_SECRET:-}" ]] && { log "FATAL: AVALON_JWT_SECRET unset"; exit 1; }

cleanup() {
	[[ -n "${CLIENT_PID:-}" ]] && kill "$CLIENT_PID" 2>/dev/null
	[[ -n "${WORLD_PID:-}" ]] && kill "$WORLD_PID" 2>/dev/null
	pkill -f "AVALON_PORT=$LANE_PORT" 2>/dev/null
	return 0
}
trap cleanup EXIT

TOKEN="$(python3 - "$USER_NAME" <<'PY'
import base64, hashlib, hmac, json, os, sys, time
s = os.environ["AVALON_JWT_SECRET"]; u = sys.argv[1]
b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
h = b(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
p = b(json.dumps({"sub": u, "iat": int(time.time()), "exp": int(time.time()) + 3600, "iss": "avalon"}, separators=(",", ":")).encode())
print(h + "." + p + "." + hmac.new(s.encode(), (h + "." + p).encode(), hashlib.sha256).hexdigest())
PY
)"

log "importing + booting lane world on :$LANE_PORT → live master :9100"
"$GODOT" --headless --path "$PROJECT_DIR/server/world" --import >/dev/null 2>&1
"$GODOT" --headless --path "$PROJECT_DIR/client" --import >/dev/null 2>&1
AVALON_PORT=$LANE_PORT "$GODOT" \
	--env="AVALON_JWT_SECRET=${AVALON_JWT_SECRET}" \
	--env="AVALON_PG_PASSWORD=${AVALON_PG_PASSWORD:-}" \
	--env="AVALON_PORT=$LANE_PORT" --env="AVALON_MASTER_HOST=127.0.0.1" \
	--env="AVALON_MASTER_PORT=9100" --env="AVALON_SPAWN_FIXED=1" \
	--env="AVALON_OPS_PORT=$LANE_OPS_PORT" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/server/world" --scene res://scenes/main.tscn >"$WORLD_LOG" 2>&1 &
WORLD_PID=$!
for _ in $(seq 1 40); do
	grep -q "listening on enet://0.0.0.0:$LANE_PORT" "$WORLD_LOG" 2>/dev/null && break
	sleep 1
done
grep -q "listening on enet://0.0.0.0:$LANE_PORT" "$WORLD_LOG" || {
	log "FATAL: lane world never bound :$LANE_PORT"; tail -20 "$WORLD_LOG"; exit 1; }
log "lane world up"

psql_exec "INSERT INTO auth.sessions (token,username,issued_at,expires_at,revoked)
	VALUES ('$TOKEN','$USER_NAME',NOW(),NOW()+INTERVAL '1 hour',false)
	ON CONFLICT (token) DO UPDATE SET username='$USER_NAME',revoked=false;"
psql_exec "INSERT INTO chars.characters (username, name, slot, name_chosen)
	SELECT '$USER_NAME','$USER_NAME',0,false WHERE NOT EXISTS (
		SELECT 1 FROM chars.characters
		WHERE (username='$USER_NAME' OR name='$USER_NAME') AND deleted_at IS NULL)
	ON CONFLICT DO NOTHING;"

rm -rf "$PILOT_DIR"; mkdir -p "$PILOT_DIR"
# AVALON_OBSERVE=1 is REQUIRED, not decoration: main.gd quits a headless client the moment the
# world is ready ("nothing to drive without a display") unless observe mode is on. Without it the
# pilot prints its banner, the client exits, and every op times out on a missing ack.
log "launching piloted headless client → :$LANE_PORT"
"$GODOT" \
	--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=$LANE_PORT" --env="AVALON_TOKEN=$TOKEN" \
	--env="AVALON_PILOT=1" --env="AVALON_PILOT_DIR=$PILOT_DIR" \
	--env="AVALON_COMBAT_TRACE=1" \
	--env="AVALON_OBSERVE=1" --env="AVALON_OBSERVE_SECS=300" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/client" --scene res://scenes/main.tscn \
	>"$PILOT_DIR/client.log" 2>&1 &
CLIENT_PID=$!
for _ in $(seq 1 40); do
	grep -q "\[pilot\] active" "$PILOT_DIR/client.log" 2>/dev/null && break
	sleep 1
done
grep -q "\[pilot\] active" "$PILOT_DIR/client.log" || {
	log "FATAL: pilot never came up"; tail -20 "$PILOT_DIR/client.log"; exit 1; }
log "pilot active — driving two fights with ONE toggle press"

AVALON_PILOT_DIR="$PILOT_DIR" python3 "$SCRIPT_DIR/qa/t729_two_fights.py"
RC=$?
if [[ $RC -ne 0 ]]; then
	kill -0 "$CLIENT_PID" 2>/dev/null && log "client PID $CLIENT_PID ALIVE" || log "client PID DEAD"
	log "--- client log tail ---"; tail -15 "$PILOT_DIR/client.log"
	log "--- pilot dir ---"; ls -la "$PILOT_DIR"
	log "--- world log tail ---"; tail -10 "$WORLD_LOG"
fi
[[ $RC -eq 0 ]] && log "PASS" || log "FAIL (rc=$RC)"
exit $RC
