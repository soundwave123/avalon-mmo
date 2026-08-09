#!/usr/bin/env bash
# T-426 E2E: the two NEW tutorial credit verbs proven through the REAL stack
# (client → world → master → Postgres), per the integration-harness rule.
#   1. EQUIP: a warrior with q_tut_02 active equips the leather cap (equip intent) →
#      the master credits the `equip` objective (objective_index 0).
#   2. USE_ABILITY: a mage with q_tut_02 active casts an ability at a wolf →
#      world._on_use_ability → world_rpc._on_ability_used → master credit_ability →
#      the `use_ability` "*" objective (objective_index 1) is credited.
# q_tut_02 has prerequisite q_tut_01, so we seed q_tut_01 complete. Requires a running
# stack (dev-up) + podman postgres + a display for the pilot. Exit 1 on any failed assert.
set -uo pipefail
cd "$(dirname "$0")/.."

psql_q() { podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c "$1"; }
fail() { echo "TUTORIAL E2E: FAIL — $1"; ./scripts/pilot.py quit >/dev/null 2>&1; exit 1; }
step() { echo "[tut-e2e] $1"; }

wait_obj() {  # wait_obj <cid> <quest> <index> <expected> — poll up to 20s for the async credit
	for _t in $(seq 1 10); do
		local got
		got=$(psql_q "SELECT progress FROM chars.character_quest_objectives
		              WHERE character_id=$1 AND quest_id='$2' AND objective_index=$3")
		[ "$got" = "$4" ] && return 0
		sleep 2
	done
	return 1
}

seed_char() {  # seed_char <username> <class> ; returns cid via echo. q_tut_01 complete, q_tut_02 active+zeroed
	local u=$1 cls=$2
	psql_q "INSERT INTO chars.characters (username) VALUES ('$u') ON CONFLICT (username) DO NOTHING;" >/dev/null
	local cid
	cid=$(psql_q "SELECT id FROM chars.characters WHERE username='$u'")
	psql_q "UPDATE chars.characters SET class='$cls', class_locked=true, level=5, xp=0 WHERE id=$cid;
	        DELETE FROM inventory.character_items WHERE character_id=$cid;
	        DELETE FROM chars.character_quests WHERE character_id=$cid;
	        DELETE FROM chars.character_quest_objectives WHERE character_id=$cid;
	        INSERT INTO chars.character_quests (character_id, quest_id, state, completed_at)
	          VALUES ($cid,'q_tut_01','complete', now());
	        INSERT INTO chars.character_quests (character_id, quest_id, state)
	          VALUES ($cid,'q_tut_02','active');
	        INSERT INTO chars.character_quest_objectives (character_id, quest_id, objective_index, progress)
	          VALUES ($cid,'q_tut_02',0,0),($cid,'q_tut_02',1,0);" >/dev/null
	echo "$cid"
}

# ---- 1. EQUIP verb (warrior) --------------------------------------------------------------
W=tut_equip
step "seeding warrior $W with q_tut_02 active + a leather cap in bag slot 0"
WID=$(seed_char "$W" warrior)
psql_q "INSERT INTO inventory.character_items (character_id, slot_type, slot_index, item_id, item_count)
        VALUES ($WID,'bag',0,'itm_leather_cap',1);" >/dev/null

step "warrior pilot up"
./scripts/pilot-up.sh "$W" >/dev/null 2>&1 &
sleep 30
./scripts/pilot.py state >/dev/null 2>&1 || fail "warrior pilot never came up"

step "equip bag slot 0 (the leather cap)"
./scripts/pilot.py intent '{"type":"equip","bag_slot":0}' >/dev/null 2>&1
if wait_obj "$WID" q_tut_02 0 1; then
	step "1/2 EQUIP PASS — the equip objective was credited on the live stack"
else
	fail "equip objective never credited (index 0 still $(psql_q "SELECT progress FROM chars.character_quest_objectives WHERE character_id=$WID AND quest_id='q_tut_02' AND objective_index=0"))"
fi
./scripts/pilot.py quit >/dev/null 2>&1
sleep 3

# ---- 2. USE_ABILITY verb (mage) -----------------------------------------------------------
M=tut_ability
step "seeding mage $M with q_tut_02 active"
MID=$(seed_char "$M" mage)

step "mage pilot up"
./scripts/pilot-up.sh "$M" >/dev/null 2>&1 &
sleep 30
./scripts/pilot.py state >/dev/null 2>&1 || fail "mage pilot never came up"

step "move to the wolf field and cast fire_blast (instant, ranged) at a wolf"
./scripts/pilot.py goto 30 25 >/dev/null 2>&1
sleep 2
TGT=$(./scripts/pilot.py target 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('entity_id', d.get('target_id','')))" 2>/dev/null)
step "nearest mob entity_id=$TGT"
[ -n "$TGT" ] && [ "$TGT" != "None" ] || fail "no mob to target near the wolf field"
# fire_blast = ability 202 (instant, range 25). Credit fires the moment the use is accepted.
./scripts/pilot.py intent "{\"type\":\"use_ability\",\"ability_id\":202,\"target_id\":$TGT}" >/dev/null 2>&1
if wait_obj "$MID" q_tut_02 1 1; then
	step "2/2 USE_ABILITY PASS — the use_ability objective was credited on the live stack"
else
	fail "use_ability objective never credited (index 1 still $(psql_q "SELECT progress FROM chars.character_quest_objectives WHERE character_id=$MID AND quest_id='q_tut_02' AND objective_index=1"))"
fi
./scripts/pilot.py quit >/dev/null 2>&1

echo "TUTORIAL E2E: PASS — equip + use_ability credit end-to-end on the real stack"
