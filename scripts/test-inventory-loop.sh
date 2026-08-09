#!/usr/bin/env bash
# test-inventory-loop.sh — Prove an inventory op (equip) over real ENet (T-049).
#
# Seed itm_leather_cap (a head item) in bag slot 0, connect, get_inventory, equip(0), and assert the
# server moved it to the head equip slot + cleared the bag slot. Asserts only server-emitted state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GODOT="org.godotengine.Godot"
WORLD_DIR="$PROJECT_DIR/server/world"
LOG="/tmp/avalon-inv-loop-client.log"
RESULT="/tmp/avalon-inv-loop-result.json"
USER_NAME="inv_loop"
ITEM="itm_leather_cap"

log() { echo "[test-inventory-loop] $*"; }
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

log "Seeding session + character + bag item ($ITEM @ bag[0]) for $USER_NAME..."
psql_exec "INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked)
	VALUES ('$TOKEN', '$USER_NAME', NOW(), NOW() + INTERVAL '1 hour', false)
	ON CONFLICT (token) DO UPDATE SET username='$USER_NAME', revoked=false;" >/dev/null
psql_exec "INSERT INTO chars.characters (username) VALUES ('$USER_NAME')
	ON CONFLICT (username) DO UPDATE SET level=1, xp=0;" >/dev/null
CID="$(psql_val "SELECT id FROM chars.characters WHERE username='$USER_NAME';")"
[[ -z "$CID" ]] && { log "FATAL: no character id"; exit 1; }
psql_exec "DELETE FROM inventory.character_items WHERE character_id=$CID;" >/dev/null
psql_exec "INSERT INTO inventory.character_items (character_id, slot_type, slot_index, item_id, item_count)
	VALUES ($CID, 'bag', 0, '$ITEM', 1);" >/dev/null

log "Running inventory client (get_inventory → equip(0)) over ENet..."
rm -f "$RESULT" "$LOG"
timeout 90 flatpak run \
	--env="AVALON_HOST=127.0.0.1" \
	--env="AVALON_PORT=9200" \
	--env="AVALON_TOKEN=$TOKEN" \
	--env="AVALON_RESULT_FILE=$RESULT" \
	--env="AVALON_INV_MODE=1" \
	--env="AVALON_INV_BAG_SLOT=0" \
	--env="AVALON_INV_ITEM=$ITEM" \
	--env="AVALON_INV_EQUIP_SLOT=head" \
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
    print(f"[test-inventory-loop] FAIL — no result ({exc})")
    sys.exit(1)
errors = []
if client_exit != 0:
    errors.append(f"client exit={client_exit}")
if r.get("handshake_ok") is not True:
    errors.append("handshake_ok != true")
if r.get("bag_had_item") is not True:
    errors.append("bag_had_item != true (get_inventory didn't return the seeded item)")
if r.get("equipped") is not True:
    errors.append("equipped != true (equip didn't move it to the head slot server-side)")
if r.get("bag_cleared") is not True:
    errors.append("bag_cleared != true (bag slot still occupied after equip)")
if errors:
    print("[test-inventory-loop] FAIL — " + "; ".join(errors))
    print("[test-inventory-loop] result=" + json.dumps(r, separators=(",", ":")))
    sys.exit(1)
print("[test-inventory-loop] PASS — equip moved bag[0] → head over real ENet (server-confirmed slots)")
PYEOF
assert_exit=$?

psql_exec "DELETE FROM inventory.character_items WHERE character_id=$CID;" >/dev/null 2>&1
exit $assert_exit
