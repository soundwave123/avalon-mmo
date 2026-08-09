#!/usr/bin/env bash
# test-quest-loop.sh — Prove one full quest loop over real ENet (M2 audit gate, T-047).
#
# Mirrors test-kill-loop.sh. Starts/reuses the server stack, seeds a master session
# AND a character row for the quest user, clears any prior quest progress, then runs one
# headless client in QUEST mode: accept_quest(q_tut_01) -> kill dummy 1001 -> request_quest_log
# -> turn_in. Asserts only server-emitted results: accepted, objective credited over the
# wire, quest turned in, reward granted. (T-707 retired the old q007 fixture; q_tut_01 keeps the
# same giver anchor + dummy kill — its reach ring auto-credits at accept and the token collect
# rides the T-709 quest-drop guarantee.)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GODOT="org.godotengine.Godot"
WORLD_DIR="$PROJECT_DIR/server/world"
QUEST_LOG="/tmp/avalon-quest-loop-client.log"
QUEST_RESULT="/tmp/avalon-quest-loop-result.json"
QUEST_USER="quest_loop"
QUEST_ID="q_tut_01"

log() { echo "[test-quest-loop] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then
	set -a
	# shellcheck disable=SC1091
	source "$PROJECT_DIR/.env"
	set +a
fi
if [[ -z "${AVALON_JWT_SECRET:-}" ]]; then
	log "FATAL: AVALON_JWT_SECRET not set (.env missing?)"
	exit 1
fi
export AVALON_JWT_SECRET
export AVALON_JWT_REFRESH_SECRET="${AVALON_JWT_REFRESH_SECRET:-}"
export AVALON_PG_PASSWORD="${AVALON_PG_PASSWORD:-}"

_started_servers=false
servers_up() {
	ss -ulnp 2>/dev/null | grep -q ":9200" && ss -tlnp 2>/dev/null | grep -q ":9100"
}
cleanup() {
	if [[ "$_started_servers" == "true" ]]; then
		log "Stopping servers..."
		bash scripts/dev-down.sh >/dev/null 2>&1
	fi
}
trap cleanup EXIT

if servers_up; then
	log "Using existing servers"
else
	log "Starting servers..."
	bash scripts/dev-up.sh >/dev/null 2>&1
	_started_servers=true
	sleep 4
fi
if ! servers_up; then
	log "FATAL: servers not ready on 9100/9200"
	exit 1
fi

# Seed JWT + master session for the quest user.
TOKEN="$(python3 - << PYEOF
import base64, hashlib, hmac, json, os, time
secret = os.environ["AVALON_JWT_SECRET"]
def b64url(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
header = b64url(json.dumps({"alg":"HS256","typ":"JWT"},separators=(",",":")).encode())
payload = b64url(json.dumps({"sub":"$QUEST_USER","iat":int(time.time()),
    "exp":int(time.time())+3600,"iss":"avalon"},separators=(",",":")).encode())
sig = hmac.new(secret.encode(), (header+"."+payload).encode(), hashlib.sha256).hexdigest()
print(header+"."+payload+"."+sig)
PYEOF
)"
if [[ -z "$TOKEN" ]]; then
	log "FATAL: token generation failed"
	exit 1
fi

log "Seeding session + character for $QUEST_USER, clearing prior $QUEST_ID progress..."
psql_exec "INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked)
	VALUES ('$TOKEN', '$QUEST_USER', NOW(), NOW() + INTERVAL '1 hour', false)
	ON CONFLICT (token) DO UPDATE SET username='$QUEST_USER', revoked=false;" >/dev/null
psql_exec "INSERT INTO chars.characters (username) VALUES ('$QUEST_USER')
	ON CONFLICT (username) DO UPDATE SET level=1, xp=0;" >/dev/null
psql_exec "DELETE FROM chars.character_quest_objectives WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$QUEST_USER');
	DELETE FROM chars.character_quests WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$QUEST_USER');" >/dev/null

log "Running quest-loop client (accept $QUEST_ID -> kill 1001 -> turn_in) over ENet..."
rm -f "$QUEST_RESULT" "$QUEST_LOG"
timeout 120 flatpak run \
	--env="AVALON_HOST=127.0.0.1" \
	--env="AVALON_PORT=9200" \
	--env="AVALON_TOKEN=$TOKEN" \
	--env="AVALON_RESULT_FILE=$QUEST_RESULT" \
	--env="AVALON_QUEST_MODE=1" \
	--env="AVALON_QUEST_ID=$QUEST_ID" \
	--env="AVALON_USE_ABILITY=1" \
	--env="AVALON_ABILITY_ID=1" \
	--env="AVALON_ABILITY_TARGET=1001" \
	--env="AVALON_ABILITY_REPEAT=20" \
	--env="AVALON_ABILITY_GAP_MS=1600" \
	--env="AVALON_ABILITY_MOVE_TO_TARGET=1" \
	--filesystem="$PROJECT_DIR" \
	--filesystem=/tmp \
	"$GODOT" --headless --path "$WORLD_DIR" \
	--scene res://tests/test_client.tscn > "$QUEST_LOG" 2>&1
quest_exit=$?

python3 - "$QUEST_RESULT" "$quest_exit" << 'PYEOF'
import json, sys
result_path, client_exit = sys.argv[1], int(sys.argv[2])
try:
    with open(result_path, "r", encoding="utf-8") as fh:
        r = json.load(fh)
except Exception as exc:
    print(f"[test-quest-loop] FAIL — could not read result: {exc}")
    sys.exit(1)

errors = []
if client_exit != 0:
    errors.append(f"client exit={client_exit}")
if r.get("handshake_ok") is not True:
    errors.append("handshake_ok != true")
if r.get("accept_ok") is not True:
    errors.append("accept_ok != true (quest not accepted over the wire)")
if r.get("mob_killed") is not True:
    errors.append("mob_killed != true")
if int(r.get("objective_credited", 0)) < 1:
    errors.append(f"objective_credited={r.get('objective_credited')} (kill not credited over the wire)")
if r.get("turn_in_ok") is not True:
    errors.append("turn_in_ok != true")
# T-058: accept/kill-credit/turn-in must each have pushed targeted deltas (event-driven).
if int(r.get("quest_delta_count", 0)) < 2:
    errors.append(f"expected targeted quest_delta pushes (got {r.get('quest_delta_count')})")
if int(r.get("npc_delta_count", 0)) < 2:
    errors.append(f"expected targeted npc_indicator_delta pushes (got {r.get('npc_delta_count')})")
# T-060: the XP reward must push a player_stats payload (the HUD XP bar) to the peer.
stats = r.get("player_stats_last", {})
if int(stats.get("level", 0)) < 1 or int(stats.get("xp_for_next_level", -1)) < 0:
    errors.append(f"no player_stats after the XP-awarding turn-in: {stats}")
if r.get("pass") is not True:
    errors.append("pass != true")

if errors:
    print("[test-quest-loop] FAIL — " + "; ".join(errors))
    print("[test-quest-loop] result=" + json.dumps(r, separators=(",", ":")))
    sys.exit(1)

print(
    "[test-quest-loop] PASS — handshake=true, accepted=true, kill_credited=%d, turn_in=true, reward_xp=%d, xp_bar_payload=received"
    % (int(r.get("objective_credited", 0)), int(r.get("reward_xp", 0)))
)
PYEOF
assert_exit=$?

# Clean the test character's quest rows (leave the row; harmless + reused next run).
psql_exec "DELETE FROM chars.character_quest_objectives WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$QUEST_USER');
	DELETE FROM chars.character_quests WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$QUEST_USER');" >/dev/null 2>&1

exit $assert_exit
