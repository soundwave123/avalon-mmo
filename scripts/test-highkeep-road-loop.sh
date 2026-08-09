#!/usr/bin/env bash
# T-216: real-ENet proof for q010 -> q013, from Elmsvale to Highkeep.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORLD_DIR="$PROJECT_DIR/server/world"
RESULT="/tmp/avalon-highkeep-road-result.json"
LOG="/tmp/avalon-highkeep-road-client.log"
USER_NAME="highkeep_road_loop"
GODOT="org.godotengine.Godot"

cd "$PROJECT_DIR"

log() { echo "[test-highkeep-road-loop] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -Atc "$1"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then
	set -a
	# shellcheck disable=SC1091
	source "$PROJECT_DIR/.env"
	set +a
fi
if [[ -z "${AVALON_JWT_SECRET:-}" ]]; then
	log "FATAL: AVALON_JWT_SECRET not set"
	exit 1
fi

servers_up() {
	ss -ulnp 2>/dev/null | grep -q ":9200" && ss -tlnp 2>/dev/null | grep -q ":9100"
}
if ! servers_up; then
	log "FATAL: fresh server stack required on 9100/9200"
	exit 1
fi

TOKEN="$(python3 - <<PYEOF
import base64, hashlib, hmac, json, os, time
secret = os.environ["AVALON_JWT_SECRET"]
def b64url(data): return base64.urlsafe_b64encode(data).rstrip(b"=").decode()
header = b64url(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(",", ":")).encode())
payload = b64url(json.dumps({"sub":"$USER_NAME","iat":int(time.time()),"exp":int(time.time())+3600,"iss":"avalon"}, separators=(",", ":")).encode())
sig = hmac.new(secret.encode(), (header+"."+payload).encode(), hashlib.sha256).hexdigest()
print(header+"."+payload+"."+sig)
PYEOF
)"

log "Seeding isolated character and clearing prior chain state"
psql_exec "INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked)
	VALUES ('$TOKEN', '$USER_NAME', NOW(), NOW() + INTERVAL '1 hour', false)
	ON CONFLICT (token) DO UPDATE SET username='$USER_NAME', revoked=false;" >/dev/null
psql_exec "INSERT INTO chars.characters (username, level, spawn_x, spawn_y)
	VALUES ('$USER_NAME', 15, 0, 0)
	ON CONFLICT (username) DO UPDATE SET level=15, xp=0, coins=100, spawn_x=0, spawn_y=0;" >/dev/null
psql_exec "DELETE FROM chars.character_quest_objectives WHERE character_id IN
	(SELECT id FROM chars.characters WHERE username='$USER_NAME');
	DELETE FROM chars.character_quests WHERE character_id IN
	(SELECT id FROM chars.characters WHERE username='$USER_NAME');
	DELETE FROM inventory.character_items WHERE character_id IN
	(SELECT id FROM chars.characters WHERE username='$USER_NAME');" >/dev/null

rm -f "$RESULT" "$LOG"
log "Running q010 -> q013 over real ENet"
timeout 180 flatpak run \
	--env="AVALON_HOST=127.0.0.1" \
	--env="AVALON_PORT=9200" \
	--env="AVALON_TOKEN=$TOKEN" \
	--env="AVALON_RESULT_FILE=$RESULT" \
	--env="AVALON_ROAD_CHAIN_MODE=1" \
	--filesystem="$PROJECT_DIR" \
	--filesystem=/tmp \
	"$GODOT" --headless --path "$WORLD_DIR" \
	--scene res://tests/test_client.tscn >"$LOG" 2>&1
client_exit=$?

python3 - "$RESULT" "$client_exit" <<'PYEOF'
import json, sys
path, client_exit = sys.argv[1], int(sys.argv[2])
try:
    with open(path, encoding="utf-8") as fh:
        result = json.load(fh)
except Exception as exc:
    print(f"[test-highkeep-road-loop] FAIL — no result: {exc}")
    sys.exit(1)
errors = []
if client_exit != 0: errors.append(f"client exit={client_exit}")
if result.get("road_chain_mode") is not True: errors.append("road_chain_mode != true")
if result.get("completed") != ["q010", "q011", "q012", "q013"]:
    errors.append(f"completed={result.get('completed')}")
if result.get("letter_received") is not True: errors.append("letter was not received")
if result.get("letter_removed") is not True: errors.append("letter was not removed")
if result.get("voucher_received") is not True: errors.append("voucher was not received")
if int(result.get("coins_awarded", 0)) != 250: errors.append(f"coins_awarded={result.get('coins_awarded')}")
if result.get("pass") is not True: errors.append("pass != true")
if errors:
    print("[test-highkeep-road-loop] FAIL — " + "; ".join(errors))
    print(json.dumps(result, separators=(",", ":")))
    sys.exit(1)
print("[test-highkeep-road-loop] PASS — q010..q013 completed; letter consumed; 250 coins + voucher granted")
PYEOF
assert_exit=$?

if [[ $assert_exit -eq 0 ]]; then
	states="$(psql_exec "SELECT string_agg(quest_id || ':' || state, ',' ORDER BY quest_id)
		FROM chars.character_quests WHERE character_id=(SELECT id FROM chars.characters WHERE username='$USER_NAME');")"
	coins="$(psql_exec "SELECT coins FROM chars.characters WHERE username='$USER_NAME';")"
	voucher="$(psql_exec "SELECT COALESCE(SUM(item_count),0) FROM inventory.character_items WHERE character_id=
		(SELECT id FROM chars.characters WHERE username='$USER_NAME') AND item_id='itm_vault_voucher';")"
	letter="$(psql_exec "SELECT COALESCE(SUM(item_count),0) FROM inventory.character_items WHERE character_id=
		(SELECT id FROM chars.characters WHERE username='$USER_NAME') AND item_id='itm_letter_of_introduction';")"
	if [[ "$states" != "q010:complete,q011:complete,q012:complete,q013:complete" || "$coins" != "350" || "$voucher" != "1" || "$letter" != "0" ]]; then
		log "FAIL — DB states=$states coins=$coins voucher=$voucher letter=$letter"
		assert_exit=1
	else
		log "DB PASS — states=$states coins=$coins voucher=$voucher letter=$letter"
	fi
fi

exit $assert_exit
