#!/usr/bin/env bash
# test-client-loop.sh — Prove the REAL client (client/scenes/main.tscn) connects to the world over
# ENet, completes the session handshake, and round-trips a quest intent (T-048 Slice B/C).
#
# Mirrors test-quest-loop.sh but drives the client project's main.gd transport in net-smoke mode:
# connect → handshake → accept_quest(q_tut_01) → accept_quest_result. Asserts only server-emitted state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GODOT="org.godotengine.Godot"
CLIENT_DIR="$PROJECT_DIR/client"
CLIENT_LOG="/tmp/avalon-client-loop.log"
CLIENT_RESULT="/tmp/avalon-client-loop-result.json"
CLIENT_USER="client_loop"

log() { echo "[test-client-loop] $*"; }
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

TOKEN="$(python3 - << PYEOF
import base64, hashlib, hmac, json, os, time
secret = os.environ["AVALON_JWT_SECRET"]
def b64url(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
header = b64url(json.dumps({"alg":"HS256","typ":"JWT"},separators=(",",":")).encode())
payload = b64url(json.dumps({"sub":"$CLIENT_USER","iat":int(time.time()),
    "exp":int(time.time())+3600,"iss":"avalon"},separators=(",",":")).encode())
sig = hmac.new(secret.encode(), (header+"."+payload).encode(), hashlib.sha256).hexdigest()
print(header+"."+payload+"."+sig)
PYEOF
)"
[[ -z "$TOKEN" ]] && { log "FATAL: token gen failed"; exit 1; }

log "Seeding session + character for $CLIENT_USER, clearing prior quest progress..."
psql_exec "INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked)
	VALUES ('$TOKEN', '$CLIENT_USER', NOW(), NOW() + INTERVAL '1 hour', false)
	ON CONFLICT (token) DO UPDATE SET username='$CLIENT_USER', revoked=false;" >/dev/null
psql_exec "INSERT INTO chars.characters (username) VALUES ('$CLIENT_USER')
	ON CONFLICT (username) DO UPDATE SET level=1, xp=0;" >/dev/null
psql_exec "DELETE FROM chars.character_quest_objectives WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$CLIENT_USER');
	DELETE FROM chars.character_quests WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$CLIENT_USER');" >/dev/null

log "Running the real client headless (net-smoke: connect → handshake → accept q_tut_01)..."
rm -f "$CLIENT_RESULT" "$CLIENT_LOG"
timeout 60 flatpak run \
	--env="AVALON_HOST=127.0.0.1" \
	--env="AVALON_PORT=9200" \
	--env="AVALON_TOKEN=$TOKEN" \
	--env="AVALON_NET_SMOKE=1" \
	--env="AVALON_RESULT_FILE=$CLIENT_RESULT" \
	--filesystem="$PROJECT_DIR" \
	--filesystem=/tmp \
	"$GODOT" --headless --path "$CLIENT_DIR" \
	--scene res://scenes/main.tscn > "$CLIENT_LOG" 2>&1
client_exit=$?

python3 - "$CLIENT_RESULT" "$client_exit" << 'PYEOF'
import json, sys
path, client_exit = sys.argv[1], int(sys.argv[2])
try:
    with open(path, "r", encoding="utf-8") as fh:
        r = json.load(fh)
except Exception as exc:
    print(f"[test-client-loop] FAIL — no result ({exc})")
    sys.exit(1)
errors = []
if client_exit != 0:
    errors.append(f"client exit={client_exit}")
if r.get("handshake_ok") is not True:
    errors.append("handshake_ok != true (client never completed the session handshake)")
if r.get("accept_ok") is not True:
    errors.append("accept_ok != true (accept_quest intent did not round-trip)")
if int(r.get("marker_nodes", 0)) < 1:
    errors.append("marker_nodes < 1 (npc_indicators round-trip / marker layer did not populate)")
if int(r.get("kit_size", 0)) < 1:
    errors.append("kit_size < 1 (T-072: class_kit was dropped by the router — action bar dead)")
if errors:
    print("[test-client-loop] FAIL — " + "; ".join(errors))
    print("[test-client-loop] result=" + json.dumps(r, separators=(",", ":")))
    sys.exit(1)
print(
    "[test-client-loop] PASS — real client: connect → handshake → class_kit(%d abilities) → accept_quest → npc_indicators → %d markers, all over ENet"
    % (int(r.get("kit_size", 0)), int(r.get("marker_nodes", 0)))
)
PYEOF
assert_exit=$?

psql_exec "DELETE FROM chars.character_quest_objectives WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$CLIENT_USER');
	DELETE FROM chars.character_quests WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$CLIENT_USER');" >/dev/null 2>&1

exit $assert_exit
