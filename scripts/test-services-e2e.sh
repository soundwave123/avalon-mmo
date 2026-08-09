#!/usr/bin/env bash
# T-208 E2E: the cross-player economy proven through the REAL stack (client → world →
# master → Postgres), per the integration-harness rule. Sequential two-user flow:
#   1. svc_seller lists iron_ingot x2 (panel button click) — lot live in market.auctions,
#      stack leaves the seller's bag (escrow).
#   2. svc_buyer buys it out — coins move (buyer -25, seller +25), item lands in the
#      buyer's bag, lot closes 'sold'.
#   3. Vault relog persistence: buyer deposits the ingots, relogs, stack still vaulted.
#   4. Trainer gates: L1 mage train REJECTED (level_too_low); at L2 the purchase lands in
#      chars.character_abilities and the kit grows by one (pilot state kit_size).
# Requires a running stack (dev-up) + podman postgres. Exit 1 on any failed assertion.
set -uo pipefail
cd "$(dirname "$0")/.."

psql_q() { podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c "$1"; }

wait_db() {  # wait_db <sql> <expected> — poll up to 20s for an async write to land
	for _try in 1 2 3 4 5 6 7 8 9 10; do
		local got
		got=$(psql_q "$1")
		if [ "$got" = "$2" ]; then return 0; fi
		sleep 2
	done
	return 1
}
fail() { echo "SERVICES E2E: FAIL — $1"; exit 1; }
step() { echo "[services-e2e] $1"; }

SELLER=svc_seller
BUYER=svc_buyer

step "seeding characters + inventory"
psql_q "INSERT INTO chars.characters (username) VALUES ('$SELLER'),('$BUYER')
        ON CONFLICT (username) DO NOTHING;" >/dev/null
SID=$(psql_q "SELECT id FROM chars.characters WHERE username='$SELLER'")
BID=$(psql_q "SELECT id FROM chars.characters WHERE username='$BUYER'")
psql_q "UPDATE chars.characters SET coins=100, class='mage', class_locked=true, level=1 WHERE id IN ($SID,$BID);
        DELETE FROM inventory.character_items WHERE character_id IN ($SID,$BID);
        DELETE FROM market.auctions WHERE seller_id IN ($SID,$BID);
        DELETE FROM chars.character_abilities WHERE character_id IN ($SID,$BID);
        INSERT INTO inventory.character_items (character_id, slot_type, slot_index, item_id, item_count)
        VALUES ($SID,'bag',0,'itm_copper_ore',2);" >/dev/null

click_svc() {  # click_svc <ButtonNamePrefix> — poll for the button (panel acks are async)
	for _try in 1 2 3 4 5 6; do
		local found
		found=$(python3 scripts/pilot.py ui 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
for c in d.get('controls',[]):
    if str(c.get('name','')).startswith('$1'):
        print(c['name']); break
")
		if [ -n "$found" ]; then echo "$found"; return 0; fi
		sleep 2
	done
	return 1
}

open_panel_at() {  # open_panel_at <npc world x> <z>
	python3 scripts/pilot.py goto "$1" "$2" >/dev/null 2>&1
	sleep 1
}

open_and_find() {  # open_and_find <npc_id> <BtnPrefix> — click NPC, wait for the button;
	# on a transient service_ack timeout, close and reopen (fresh fetch) up to 3 times.
	for _round in 1 2 3; do
		click_npc "$1" 1>&2 || return 1
		sleep 2
		local btn
		btn=$(click_svc "$2")
		if [ -n "$btn" ]; then echo "$btn"; return 0; fi
		python3 scripts/pilot.py clicknode SvcClose >/dev/null 2>&1
		sleep 2
	done
	return 1
}

click_npc() {  # click_npc <npc_id substring> — probe a pixel grid with pick, click the hit
	python3 - "$1" <<'PY'
import json, subprocess, sys
target = sys.argv[1]
def run(*args):
    r = subprocess.run(["python3", "scripts/pilot.py", *args], capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except Exception:
        return {}
for y in range(480, 861, 60):
    for x in range(660, 1381, 80):
        hit = run("pick", str(x), str(y))
        if target in str(hit.get("collider", "")):
            run("click", str(x), str(y))
            print("clicked %s at %d,%d" % (target, x, y))
            sys.exit(0)
print("npc not found on screen: %s" % target)
sys.exit(1)
PY
}

# ---- 1) seller lists --------------------------------------------------------
step "seller session"
./scripts/pilot-up.sh "$SELLER" >/dev/null 2>&1 & sleep 30
open_panel_at 31.5 -209
LIST_BTN=$(open_and_find npc_hk_auctioneer SvcList)
[ -n "$LIST_BTN" ] || fail "auction panel/list button not visible for seller"
python3 scripts/pilot.py clicknode "$LIST_BTN" >/dev/null; sleep 6
wait_db "SELECT count(*) FROM market.auctions WHERE seller_id=$SID AND state='live'" 1 \
	|| fail "listing not live"
BAGLEFT=$(psql_q "SELECT count(*) FROM inventory.character_items WHERE character_id=$SID AND slot_type='bag'")
[ "$BAGLEFT" = "0" ] || fail "listed stack still in seller bag"
step "1/4 listing PASS (lot live, stack escrowed)"

# ---- 2) buyer buys out ------------------------------------------------------
step "buyer session"
./scripts/pilot-up.sh "$BUYER" >/dev/null 2>&1 & sleep 30
open_panel_at 31.5 -209
BUY_BTN=$(open_and_find npc_hk_auctioneer SvcBuyout)
[ -n "$BUY_BTN" ] || fail "buyout button not visible for buyer"
python3 scripts/pilot.py clicknode "$BUY_BTN" >/dev/null; sleep 6
wait_db "SELECT count(*) FROM market.auctions WHERE seller_id=$SID AND state='sold'" 1 \
	|| fail "lot did not close sold"
BCOIN=$(psql_q "SELECT coins FROM chars.characters WHERE id=$BID")
SCOIN=$(psql_q "SELECT coins FROM chars.characters WHERE id=$SID")
[ "$BCOIN" = "75" ] || fail "buyer coins $BCOIN != 75"
[ "$SCOIN" = "125" ] || fail "seller coins $SCOIN != 125"
GOT=$(psql_q "SELECT count(*) FROM inventory.character_items WHERE character_id=$BID AND item_id='itm_copper_ore'")
[ "$GOT" = "1" ] || fail "buyer did not receive the ingots"
step "2/4 buyout PASS (coins moved, item delivered)"
python3 scripts/pilot.py clicknode SvcClose >/dev/null; sleep 1   # close the auction panel

# ---- 3) vault + relog persistence -------------------------------------------
open_panel_at -31 -205.5
DEP_BTN=$(open_and_find npc_hk_banker SvcDeposit)
[ -n "$DEP_BTN" ] || fail "deposit button not visible"
python3 scripts/pilot.py clicknode "$DEP_BTN" >/dev/null; sleep 6
wait_db "SELECT count(*) FROM inventory.character_items WHERE character_id=$BID AND slot_type='vault'" 1 \
	|| fail "deposit did not persist"
step "relog"
./scripts/pilot-up.sh "$BUYER" >/dev/null 2>&1 & sleep 30
STILL=$(psql_q "SELECT count(*) FROM inventory.character_items WHERE character_id=$BID AND slot_type='vault'")
[ "$STILL" = "1" ] || fail "vault did not survive relog"
step "3/4 vault relog PASS"
python3 scripts/pilot.py clicknode SvcClose >/dev/null; sleep 1

# ---- 4) trainer gates + kit growth -------------------------------------------
open_panel_at 94.5 -262
KIT_BEFORE=$(python3 scripts/pilot.py state 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['state']['kit_size'])")
TRAIN_BTN=$(open_and_find npc_hk_mage_trainer SvcTrain)
[ -n "$TRAIN_BTN" ] || fail "train button not visible"
python3 scripts/pilot.py clicknode "$TRAIN_BTN" >/dev/null; sleep 6
KNOWN=$(psql_q "SELECT count(*) FROM chars.character_abilities WHERE character_id=$BID")
[ "$KNOWN" = "0" ] || fail "L1 train should have been rejected (level gate)"
step "level gate held at L1 — promoting to L2"
psql_q "UPDATE chars.characters SET level=2 WHERE id=$BID" >/dev/null
python3 scripts/pilot.py clicknode "$TRAIN_BTN" >/dev/null; sleep 6
wait_db "SELECT count(*) FROM chars.character_abilities WHERE character_id=$BID" 1 \
	|| fail "train purchase did not persist at L2"
sleep 1
KIT_AFTER=$(python3 scripts/pilot.py state 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['state']['kit_size'])")
[ "$KIT_AFTER" -gt "$KIT_BEFORE" ] || fail "kit did not grow after training ($KIT_BEFORE -> $KIT_AFTER)"
step "4/4 trainer PASS (gate at L1, unlock + kit growth at L2)"

echo "SERVICES E2E: PASS"
