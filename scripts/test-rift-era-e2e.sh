#!/usr/bin/env bash
# T-369 E2E: rift/era EDGE CASES through the REAL stack (two piloted clients a1, a2).
# Integration-harness rule — party/era scope + the positions broadcast bucket hide from unit tests;
# the pure edge-case logic is proven by test_rift_era.gd (dead-cross reject, auto-drop, era-2
# respawn point), and THIS is the live proof of the drivable case: PARTY SPLIT ACROSS ERAS.
#
# What it proves live:
#   1. Two grouped players; one crosses the rift (enter_era) -> the crosser is AUTO-DROPPED from the
#      party (spike rule, era-direction.md §6), and the 2-member party auto-disbands (both end
#      party-less). No undefined split-party state.
#   2. The crosser lands in the ERA-2 Ashmoor offset region (far WEST, x<0, |pos|>330) and its
#      broadcast is region-isolated (T-371): it no longer carries the era-1 partner.
#
# NOT driven here (unit-proven, not live): case 2 death-DURING-crossing (a dead player is rejected —
# test_enter_era_rejects_a_dead_player) and case 3 era-2 respawn point (respawn_point returns
# ASHMOOR_RESPAWN for an Ashmoor death — test_respawn_in_ashmoor_uses_the_era2_point). Ashmoor is a
# MOB-LESS spike (no hostiles seeded — ashmoor.json npc_anchors are stubs), so a real player death in
# Ashmoor can't be driven end-to-end yet; wire this in when the Syndicate roster (T-349) lands.
#
# ELIGIBILITY: the rift is quest-gated (T-352 q_rift_vault_counted). This seeds that quest ACTIVE for
# both chars in chars.character_quests (the honest gate path — no env backdoor needed).
#
# RUN FROM THE ORCHESTRATOR / visual lane. Server-side .gd changes need a stack restart first
# (dev-up loads code once) — this script dev-downs then lets pilot-up boot a fresh stack.
set -uo pipefail
cd "$(dirname "$0")/.."
psql_q() { podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c "$1"; }
fail() { echo "RIFT-ERA E2E: FAIL — $1"; exit 1; }
step() { echo "[rift-e2e] $1"; }

A1=rift_a1; A2=rift_a2
D2=/tmp/avalon-pilot-rift-a2
p1() { python3 scripts/pilot.py "$@"; }
p2() { AVALON_PILOT_DIR=$D2 python3 scripts/pilot.py "$@"; }

# party_size <p-fn>: number of members on that client's last party_update (0 == party-less).
party_size() { "$@" partystate 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('party',{}).get('members') or []))"; }
# own_pos <username> <p-fn>: that client's OWN (x,y) from its last positions broadcast, as 'x y'.
own_pos() { local u="$1"; shift; "$@" positions 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin).get('positions',{}); ps=[p for p in d.get('players',[]) if p.get('username')=='$u']; print('%f %f'%(ps[0].get('x',0.0),ps[0].get('y',0.0)) if ps else '0 0')"; }
# sees_user <seen> <p-fn>: 1 if <seen> username appears in that client's last positions players list.
sees_user() { local s="$1"; shift; "$@" positions 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin).get('positions',{}); print(1 if any(p.get('username')=='$s' for p in d.get('players',[])) else 0)"; }

step "restart the stack so the world server loads the T-369 changes"
bash scripts/dev-down.sh >/dev/null 2>&1 || true
sleep 2

step "seed two warriors + the rift arrival quest ACTIVE (the honest eligibility gate)"
psql_q "INSERT INTO chars.characters (username) VALUES ('$A1'),('$A2')
        ON CONFLICT (username) DO NOTHING;
        UPDATE chars.characters SET class='warrior', class_locked=true
        WHERE username IN ('$A1','$A2');" >/dev/null
for u in "$A1" "$A2"; do
  CID=$(psql_q "SELECT id FROM chars.characters WHERE username='$u';")
  [ -n "$CID" ] || fail "could not resolve character id for $u"
  psql_q "INSERT INTO chars.character_quests (character_id, quest_id, state)
          VALUES ($CID, 'q_rift_vault_counted', 'active')
          ON CONFLICT (character_id, quest_id) DO UPDATE SET state='active';" >/dev/null
done

step "two clients up"
./scripts/pilot-up.sh "$A1" >/dev/null 2>&1 & sleep 30
AVALON_PILOT_DIR=$D2 ./scripts/pilot-up.sh "$A2" >/dev/null 2>&1 & sleep 30
sleep 4

# ---- form party {a1,a2} -------------------------------------------------------
step "party = {a1,a2}"
p1 party invite "$A2" >/dev/null; sleep 2; p2 party accept >/dev/null; sleep 2
S1=$(party_size p1); S2=$(party_size p2)
[ "$S1" = "2" ] && [ "$S2" = "2" ] || fail "party did not form (a1 sees $S1, a2 sees $S2 members)"
step "party formed (both see 2 members)"

# ---- a1 crosses the rift; a2 stays in era 1 -----------------------------------
step "a1 crosses the rift (enter_era) — the split moment"
p1 intent '{"type":"enter_era"}' >/dev/null; sleep 3

# ---- 1) PARTY SPLIT -> AUTO-DROP (both party-less) ----------------------------
S1B=$(party_size p1); S2B=$(party_size p2)
[ "$S1B" = "0" ] || fail "the crosser (a1) is still in a party ($S1B members) — auto-drop broke"
[ "$S2B" = "0" ] || fail "the stay-behind (a2) still shows a party ($S2B) — auto-disband-at-one broke"
step "1/2 party-split PASS (a1 auto-dropped on cross; the 2-member party auto-disbanded — both party-less)"

# ---- 2) the crosser is in the ERA-2 Ashmoor region, isolated ------------------
read -r AX AY <<<"$(own_pos "$A1" p1)"
# far WEST (x<0) and past the r>330 offset-region cull — the Ashmoor arrival plaza.
python3 -c "import sys; x,y=float('$AX'),float('$AY'); sys.exit(0 if (x<0 and (x*x+y*y)**0.5>330) else 1)" \
  || fail "a1 did not land in the Ashmoor offset region (pos $AX,$AY)"
# region isolation (T-371): a1's Ashmoor broadcast no longer carries the era-1 partner a2.
SEES=$(sees_user "$A2" p1)
[ "$SEES" = "0" ] || fail "a1 in Ashmoor still receives era-1 player a2 — cross-era visibility leaked"
step "2/2 era-scope PASS (a1 at Ashmoor $AX,$AY; era-1 partner a2 not in its broadcast)"

for pf in p1 p2; do $pf quit >/dev/null 2>&1; done
echo "RIFT-ERA E2E: PASS"
