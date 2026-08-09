#!/usr/bin/env bash
# T-699 lane E2E: boots an ISOLATED world server from THIS worktree on port 9210 → the LIVE master
# (9100), then runs two headless real clients against it (never touching the shared :9200 stack).
# Proves the T-699 mob DELTA frames + player delta reconstruct correctly through real ENet: a second
# real client SEES the first player (players via delta) AND the region's mobs (mob keyframe+delta
# reconstruction — entity_count > player_count). Netcode hides from unit tests (T-320); this is that.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
export AVALON_GODOT_PIN="${AVALON_GODOT_PIN:-native-4.7}"
GODOT="$SCRIPT_DIR/godot-bin.sh"
LANE_PORT=9210
LANE_OPS_PORT=9216
WORLD_LOG=/tmp/t699-lane-world.log
OBS_LOG=/tmp/t699-obs.log
MOVER_LOG=/tmp/t699-mover.log
RESULT=/tmp/t699-observer.json
log() { echo "[t699-e2e] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1" >/dev/null 2>&1; }

# Live master must be up (we reuse it; we do NOT boot or touch it).
ss -ltn 2>/dev/null | grep -q ":9100" || { log "FATAL: live master not on 9100"; exit 1; }
[[ -f "$PROJECT_DIR/.env" ]] && { set -a; source "$PROJECT_DIR/.env"; set +a; }
[[ -f /home/soundwave/avalon/.env ]] && { set -a; source /home/soundwave/avalon/.env; set +a; }
[[ -z "${AVALON_JWT_SECRET:-}" ]] && { log "FATAL: AVALON_JWT_SECRET unset"; exit 1; }

gen_token() {
	python3 - "$1" <<'PY'
import base64, hashlib, hmac, json, os, sys, time
s = os.environ["AVALON_JWT_SECRET"]; u = sys.argv[1]
b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
h = b(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
p = b(json.dumps({"sub": u, "iat": int(time.time()), "exp": int(time.time()) + 3600, "iss": "avalon"}, separators=(",", ":")).encode())
print(h + "." + p + "." + hmac.new(s.encode(), (h + "." + p).encode(), hashlib.sha256).hexdigest())
PY
}

cleanup() { [[ -n "${WORLD_PID:-}" ]] && kill "$WORLD_PID" 2>/dev/null; pkill -f "AVALON_PORT=$LANE_PORT" 2>/dev/null; }
trap cleanup EXIT

log "importing + booting lane world (worktree code) on :$LANE_PORT → live master :9100"
"$GODOT" --headless --path "$PROJECT_DIR/server/world" --import >/dev/null 2>&1
"$GODOT" --headless --path "$PROJECT_DIR/client" --import >/dev/null 2>&1
AVALON_PORT=$LANE_PORT AVALON_MASTER_HOST=127.0.0.1 AVALON_MASTER_PORT=9100 \
	AVALON_SPAWN_FIXED=1 AVALON_OPS_PORT=$LANE_OPS_PORT \
	"$GODOT" \
	--env="AVALON_JWT_SECRET=${AVALON_JWT_SECRET}" \
	--env="AVALON_PG_PASSWORD=${AVALON_PG_PASSWORD:-}" \
	--env="AVALON_PORT=$LANE_PORT" --env="AVALON_MASTER_HOST=127.0.0.1" --env="AVALON_MASTER_PORT=9100" \
	--env="AVALON_SPAWN_FIXED=1" --env="AVALON_OPS_PORT=$LANE_OPS_PORT" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/server/world" --scene res://scenes/main.tscn >"$WORLD_LOG" 2>&1 &
WORLD_PID=$!

for _ in $(seq 1 40); do
	grep -q "listening on enet://0.0.0.0:$LANE_PORT" "$WORLD_LOG" 2>/dev/null && break
	sleep 1
done
grep -q "listening on enet://0.0.0.0:$LANE_PORT" "$WORLD_LOG" || { log "FATAL: lane world never bound :$LANE_PORT"; tail -20 "$WORLD_LOG"; exit 1; }
log "lane world up on :$LANE_PORT"

for U in t699obs t699mover; do
	T="$(gen_token "$U")"
	[[ "$U" == "t699obs" ]] && TOK_OBS="$T" || TOK_MOVER="$T"
	psql_exec "INSERT INTO auth.sessions (token,username,issued_at,expires_at,revoked)
		VALUES ('$T','$U',NOW(),NOW()+INTERVAL '1 hour',false)
		ON CONFLICT (token) DO UPDATE SET username='$U',revoked=false;"
	psql_exec "INSERT INTO chars.characters (username) VALUES ('$U') ON CONFLICT (username) DO NOTHING;"
done

rm -f "$RESULT" "$OBS_LOG" "$MOVER_LOG"
log "observer + a second moving player, both on :$LANE_PORT"
timeout 40 "$GODOT" \
	--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=$LANE_PORT" --env="AVALON_TOKEN=$TOK_OBS" \
	--env="AVALON_OBSERVE=1" --env="AVALON_OBSERVE_SECS=14" --env="AVALON_RESULT_FILE=$RESULT" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/client" --scene res://scenes/main.tscn >"$OBS_LOG" 2>&1 &
OBS_PID=$!
sleep 3
timeout 20 "$GODOT" \
	--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=$LANE_PORT" --env="AVALON_TOKEN=$TOK_MOVER" \
	--env="AVALON_MOVE_DURATION=12" --env="AVALON_MOVE_SPEED=20" --env="AVALON_RESULT_FILE=/tmp/t699mover.json" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/server/world" --scene res://tests/test_client.tscn >"$MOVER_LOG" 2>&1 &
wait "$OBS_PID" 2>/dev/null

python3 - "$RESULT" <<'PY'
import json, sys
try:
	d = json.load(open(sys.argv[1]))
except Exception as e:
	print("[t699-e2e] FAIL — no observer result (%s)" % e); sys.exit(1)
players = d.get("max_remote_players", 0)
ents = d.get("max_remote_entities", 0)
mobs = ents - players
print("[t699-e2e] observer saw max_remote_players=%d max_remote_entities=%d (mobs≈%d)" % (players, ents, mobs))
if players >= 1 and mobs >= 1:
	print("[t699-e2e] PASS — player reconstructed via delta AND region mobs reconstructed via mob keyframe+delta")
	sys.exit(0)
print("[t699-e2e] FAIL — players=%d mobs=%d (delta reconstruction broken)" % (players, mobs))
sys.exit(1)
PY
