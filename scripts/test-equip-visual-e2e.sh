#!/usr/bin/env bash
# T-225 E2E: equipment shows on your character — for you AND for others, through the
# REAL stack (two piloted clients on one world). Integration-harness rule: netcode
# hides from unit tests.
#   1. equip_a is seeded with itm_iron_sword EQUIPPED; equip_b watches.
#   2. Both clients up -> A's own visual has GearSlot_weapon; B's view of A has it too
#      (positions.gear -> remote attach), with the broadcast dict naming the sword.
#   3. Live change: the sword moves back to A's bag in DB; A re-opens inventory (the
#      get_inventory reply refreshes the world's gear cache) -> both clients drop the
#      attachment.
#   4. T-228: A equips itm_leather_cap (head slot) -> both A's own visual and B's view
#      of A report GearSlot_head after an inventory refresh.
# Requires podman postgres; brings its own clients. Exit 1 on any failed assertion.
set -uo pipefail
cd "$(dirname "$0")/.."

psql_q() { podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c "$1"; }
fail() { echo "EQUIP-VISUAL E2E: FAIL — $1"; exit 1; }
step() { echo "[equip-e2e] $1"; }

A=equip_a
B=equip_b
DIR_B=/tmp/avalon-pilot2

pilot_a() { python3 scripts/pilot.py "$@"; }
pilot_b() { AVALON_PILOT_DIR=$DIR_B python3 scripts/pilot.py "$@"; }

gear_field() {  # gear_field <a|b> <python-expr over d>
	local out
	if [ "$1" = a ]; then out=$(pilot_a gear 2>/dev/null); else out=$(pilot_b gear 2>/dev/null); fi
	echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin).get('gear',{})
print($2)"
}

step "seeding: $A owns an equipped iron sword; $B is a bystander"
psql_q "INSERT INTO chars.characters (username) VALUES ('$A'),('$B')
        ON CONFLICT (username) DO NOTHING;" >/dev/null
AID=$(psql_q "SELECT id FROM chars.characters WHERE username='$A'")
psql_q "UPDATE chars.characters SET class='warrior', class_locked=true WHERE username IN ('$A','$B');
        DELETE FROM inventory.character_items WHERE character_id=$AID;
        INSERT INTO inventory.character_items (character_id, slot_type, slot_index, item_id, item_count)
        VALUES ($AID,'weapon',0,'itm_iron_sword',1);" >/dev/null

step "client A up"
./scripts/pilot-up.sh "$A" >/dev/null 2>&1 & sleep 30
step "client B up (second pilot dir)"
AVALON_PILOT_DIR=$DIR_B ./scripts/pilot-up.sh "$B" >/dev/null 2>&1 & sleep 30

sleep 6  # a few broadcast ticks
# ---- 1) A sees own weapon ----------------------------------------------------
LOCAL_A=$(gear_field a "','.join(d.get('local',[]))")
[[ "$LOCAL_A" == *GearSlot_weapon* ]] || fail "A's own visual lacks GearSlot_weapon (got '$LOCAL_A')"
step "1/3 self-view PASS (A wears the sword)"

# ---- 2) B sees A's weapon ----------------------------------------------------
REMOTE_B=$(gear_field b "json.dumps(d.get('remote',{}))")
echo "$REMOTE_B" | grep -q '"weapon": "itm_iron_sword"' || fail "B's broadcast view of A lacks the sword dict ($REMOTE_B)"
echo "$REMOTE_B" | grep -q "GearSlot_weapon" || fail "B rendered no GearSlot_weapon node for A ($REMOTE_B)"
step "2/3 other-view PASS (B sees A's sword)"

# ---- 3) live change propagates ------------------------------------------------
step "moving the sword to A's bag in DB, refreshing via A's inventory"
psql_q "UPDATE inventory.character_items SET slot_type='bag' WHERE character_id=$AID AND item_id='itm_iron_sword';" >/dev/null
pilot_a key I >/dev/null; sleep 3; pilot_a key I >/dev/null; sleep 4
LOCAL_A2=$(gear_field a "','.join(d.get('local',[]))")
[[ "$LOCAL_A2" != *GearSlot_weapon* ]] || fail "A still wears the sword after unequip refresh"
REMOTE_B2=$(gear_field b "json.dumps(d.get('remote',{}))")
echo "$REMOTE_B2" | grep -q '"weapon": "itm_iron_sword"' && fail "B still sees A's sword after unequip"
step "3/3 live-change PASS (both views dropped the sword)"

# ---- 4) T-228: head slot (leather cap) ----------------------------------------
step "seeding: $A equips itm_leather_cap (head), refreshing via A's inventory"
psql_q "INSERT INTO inventory.character_items (character_id, slot_type, slot_index, item_id, item_count)
        VALUES ($AID,'head',0,'itm_leather_cap',1);" >/dev/null
pilot_a key I >/dev/null; sleep 3; pilot_a key I >/dev/null; sleep 4
LOCAL_A3=$(gear_field a "','.join(d.get('local',[]))")
[[ "$LOCAL_A3" == *GearSlot_head* ]] || fail "A's own visual lacks GearSlot_head (got '$LOCAL_A3')"
REMOTE_B3=$(gear_field b "json.dumps(d.get('remote',{}))")
echo "$REMOTE_B3" | grep -q '"head": "itm_leather_cap"' || fail "B's broadcast view of A lacks the cap dict ($REMOTE_B3)"
echo "$REMOTE_B3" | grep -q "GearSlot_head" || fail "B rendered no GearSlot_head node for A ($REMOTE_B3)"
step "4/4 head-slot PASS (both views show A's cap)"

pilot_a quit >/dev/null 2>&1
pilot_b quit >/dev/null 2>&1
echo "EQUIP-VISUAL E2E: PASS"
