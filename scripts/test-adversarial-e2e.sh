#!/usr/bin/env bash
# T-382 E2E: the forged-ENet-peer adversarial harness. Per the standing-orders memory (netcode
# bugs hide from single-client / unit harnesses) this drives a RAW forged peer — not the trusted
# pilot — through the REAL stack (client → world → master → Postgres). It boots nothing itself:
# run it after `scripts/dev-up.sh` with Postgres up, exactly like the other *-e2e.sh scripts.
#
# The forged peer (server/world/tests/adversarial_peer.gd) completes a real session handshake, then:
#   1. forges an out-of-range cast on a real mob            → server must reject (out_of_range)
#   2. forges self-grant verbs (grant_loot/adjust_coins/…)  → server must IGNORE (no reply, no state)
#   3. floods get_inventory in a tight loop                 → throttled (rate_limited) then KICKED
# We assert the peer's JSON verdict AND that the forger's DB coins/items are byte-for-byte unchanged
# (the forged grants moved nothing). Exit 1 on any failed assertion.
set -uo pipefail
cd "$(dirname "$0")/.."

GODOT="scripts/godot-bin.sh"
USER=adv_forger
RESULT=/tmp/avalon-adv-result.json
SCENE=server/world/tests/adversarial_peer.tscn  # generated below, removed on exit (no committed .tscn)
FORGE_TARGET="${AVALON_FORGE_TARGET:-1001}"      # a real mob entity id at its far spawn

psql_q() { podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c "$1"; }
fail() { echo "ADVERSARIAL E2E: FAIL — $1"; cleanup; exit 1; }
step() { echo "[adv-e2e] $1"; }
cleanup() { rm -f "$SCENE" "$RESULT"; }
trap cleanup EXIT

# ---- seed a character so master can validate + load combat state ------------
step "seeding forger character (coins=500, one bag item)"
psql_q "INSERT INTO chars.characters (username) VALUES ('$USER') ON CONFLICT (username) DO NOTHING;
        UPDATE chars.characters SET coins=500, class='warrior', class_locked=true, level=5
          WHERE username='$USER';" >/dev/null
CID=$(psql_q "SELECT id FROM chars.characters WHERE username='$USER'")
[ -n "$CID" ] || fail "could not seed/find the forger character"
psql_q "DELETE FROM inventory.character_items WHERE character_id=$CID;
        INSERT INTO inventory.character_items (character_id, slot_type, slot_index, item_id, item_count)
        VALUES ($CID,'bag',0,'itm_copper_ore',1);" >/dev/null
COINS_BEFORE=$(psql_q "SELECT coins FROM chars.characters WHERE id=$CID")
ITEMS_BEFORE=$(psql_q "SELECT count(*) FROM inventory.character_items WHERE character_id=$CID")

# ---- mint a JWT the master will validate (same inline recipe as test-reconnect.sh) ----
step "minting session token"
TOKEN=$(python3 - "$USER" <<'PY'
import hashlib, hmac, json, base64, time, sys
secret = ""
with open(".env") as f:
    for line in f:
        if line.strip().startswith("AVALON_JWT_SECRET="):
            secret = line.strip().split("=", 1)[1]; break
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
h = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
p = b64(json.dumps({"sub": sys.argv[1], "iat": int(time.time()),
                    "exp": int(time.time()) + 3600, "iss": "avalon"}).encode())
# NOTE: shared/jwt.gd signs/verifies a HEX signature (_hmac_sha256/_hex_to_bytes), not the RFC
# base64url form — mint to match or the world rejects the handshake with invalid_signature.
sig = hmac.new(secret.encode(), (h + "." + p).encode(), hashlib.sha256).hexdigest()
print(h + "." + p + "." + sig)
PY
)
[ ${#TOKEN} -gt 20 ] || fail "failed to mint a JWT (is .env present with AVALON_JWT_SECRET?)"

# ---- generate the launch scene (root node MUST be 'Main' so the RPC node path matches world) ----
cat > "$SCENE" <<'TSCN'
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://tests/adversarial_peer.gd" id="1"]
[node name="Main" type="Node"]
script = ExtResource("1")
TSCN

# ---- run the forged peer against the live world -----------------------------
step "driving the forged peer (handshake → forgeries → flood)"
rm -f "$RESULT"
AVALON_TOKEN="$TOKEN" \
AVALON_RESULT_FILE="$RESULT" \
AVALON_FORGE_TARGET="$FORGE_TARGET" \
AVALON_FLOOD_COUNT="${AVALON_FLOOD_COUNT:-600}" \
	"$GODOT" --headless --path server/world --scene res://tests/adversarial_peer.tscn \
	--filesystem=/tmp 2>&1 | sed 's/^/[peer] /'

[ -f "$RESULT" ] || fail "forged peer wrote no result (crash/timeout — is the stack up?)"

# ---- gate on the peer's verdict --------------------------------------------
step "verdict: $(cat "$RESULT")"
jget() { python3 -c "import json,sys; print(json.load(open('$RESULT')).get('$1'))"; }
[ "$(jget handshake_ok)" = "True" ]           || fail "forged peer never completed the handshake"
[ "$(jget saw_out_of_range_reject)" = "True" ] || fail "out-of-range forged cast was NOT rejected"
[ "$(jget self_grant_replies)" = "0" ]        || fail "server REPLIED to a forged self-grant verb"
RL=$(jget intent_rate_limited); [ "${RL:-0}" -gt 0 ] || fail "intent flood was never rate_limited"
[ "$(jget server_disconnected)" = "True" ]     || fail "flooding peer was never disconnected"

# ---- gate on DB: the forged grants must have moved NOTHING ------------------
COINS_AFTER=$(psql_q "SELECT coins FROM chars.characters WHERE id=$CID")
ITEMS_AFTER=$(psql_q "SELECT count(*) FROM inventory.character_items WHERE character_id=$CID")
[ "$COINS_AFTER" = "$COINS_BEFORE" ] || fail "coins changed ($COINS_BEFORE -> $COINS_AFTER) after forged grants"
[ "$ITEMS_AFTER" = "$ITEMS_BEFORE" ] || fail "item count changed ($ITEMS_BEFORE -> $ITEMS_AFTER) after forged grants"

echo "ADVERSARIAL E2E: PASS — forgeries rejected end-to-end, flood throttled+kicked, no state change"
