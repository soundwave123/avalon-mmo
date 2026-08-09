#!/usr/bin/env bash
# test-collect-loop.sh — Prove a collect objective credits on accept over real ENet (T-049).
#
# Seed 5 itm_wolf_pelt in the bag, accept q001 (collect objective 1 wants 5 pelts), and assert the
# collect objective credits immediately — with NO inventory change (proves the accept-refresh fix).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GODOT="org.godotengine.Godot"
WORLD_DIR="$PROJECT_DIR/server/world"
LOG="/tmp/avalon-collect-loop-client.log"
RESULT="/tmp/avalon-collect-loop-result.json"
USER_NAME="collect_loop"
QUEST="q001"
ITEM="itm_wolf_pelt"

log() { echo "[test-collect-loop] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1"; }
psql_val() { podman exec -i avalon-postgres psql -U avalon -d avalon -t -c "$1" | tr -d ' \n'; }

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
servers_up || { log "FATAL: servers not ready on 9100/9200"; exit 1; }

TOKEN="$(python3 - << PYEOF
import base64, hashlib, hmac, json, os, time
secret = os.environ["AVALON_JWT_SECRET"]
def b64url(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
header = b64url(json.dumps({"alg":"HS256","typ":"JWT"},separators=(",",":")).encode())
payload = b64url(json.dumps({"sub":"$USER_NAME","iat":int(time.time()),
    "exp":int(time.time())+3600,"iss":"avalon"},separators=(",",":")).encode())
sig = hmac.new(secret.encode(), (header+"."+payload).encode(), hashlib.sha256).hexdigest()
print(header+"."+payload+"."+sig)
PYEOF
)"
[[ -z "$TOKEN" ]] && { log "FATAL: token gen failed"; exit 1; }

log "Seeding session + character + 5×$ITEM in bag for $USER_NAME, clearing prior $QUEST..."
psql_exec "INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked)
	VALUES ('$TOKEN', '$USER_NAME', NOW(), NOW() + INTERVAL '1 hour', false)
	ON CONFLICT (token) DO UPDATE SET username='$USER_NAME', revoked=false;" >/dev/null
psql_exec "INSERT INTO chars.characters (username) VALUES ('$USER_NAME')
	ON CONFLICT (username) DO UPDATE SET level=1, xp=0;" >/dev/null
CID="$(psql_val "SELECT id FROM chars.characters WHERE username='$USER_NAME';")"
[[ -z "$CID" ]] && { log "FATAL: no character id"; exit 1; }
psql_exec "DELETE FROM chars.character_quest_objectives WHERE character_id=$CID;
	DELETE FROM chars.character_quests WHERE character_id=$CID;
	DELETE FROM inventory.character_items WHERE character_id=$CID;" >/dev/null
psql_exec "INSERT INTO inventory.character_items (character_id, slot_type, slot_index, item_id, item_count)
	VALUES ($CID, 'bag', 0, '$ITEM', 5);" >/dev/null

log "Running collect client (accept $QUEST with 5 pelts already held → poll log) over ENet..."
rm -f "$RESULT" "$LOG"
timeout 90 flatpak run \
	--env="AVALON_HOST=127.0.0.1" \
	--env="AVALON_PORT=9200" \
	--env="AVALON_TOKEN=$TOKEN" \
	--env="AVALON_RESULT_FILE=$RESULT" \
	--env="AVALON_COLLECT_MODE=1" \
	--env="AVALON_COLLECT_QUEST=$QUEST" \
	--env="AVALON_COLLECT_OBJ_INDEX=1" \
	--filesystem="$PROJECT_DIR" \
	--filesystem=/tmp \
	"$GODOT" --headless --path "$WORLD_DIR" \
	--scene res://tests/test_client.tscn > "$LOG" 2>&1
client_exit=$?

python3 - "$RESULT" "$client_exit" << 'PYEOF'
import json, sys
path, client_exit = sys.argv[1], int(sys.argv[2])
try:
    with open(path, "r", encoding="utf-8") as fh:
        r = json.load(fh)
except Exception as exc:
    print(f"[test-collect-loop] FAIL — no result ({exc})")
    sys.exit(1)
errors = []
if client_exit != 0:
    errors.append(f"client exit={client_exit}")
if r.get("handshake_ok") is not True:
    errors.append("handshake_ok != true")
if r.get("accept_ok") is not True:
    errors.append("accept_ok != true")
if r.get("collect_credited") is not True:
    errors.append("collect_credited != true (accept did not credit already-held items)")
if errors:
    print("[test-collect-loop] FAIL — " + "; ".join(errors))
    print("[test-collect-loop] result=" + json.dumps(r, separators=(",", ":")))
    sys.exit(1)
print("[test-collect-loop] PASS — collect credited on accept (held items) over real ENet")
PYEOF
assert_exit=$?

psql_exec "DELETE FROM chars.character_quest_objectives WHERE character_id=$CID;
	DELETE FROM chars.character_quests WHERE character_id=$CID;
	DELETE FROM inventory.character_items WHERE character_id=$CID;" >/dev/null 2>&1
exit $assert_exit
