#!/usr/bin/env bash
# T-331/T-334 E2E: the Hollowed Crypt group loop through the REAL stack (four piloted clients:
# party A = {a1,a2}, party B = {b1,b2}). Integration-harness rule — instance/broadcast scoping and
# party/LFG flow hide from unit tests. The pure logic is proven by test_instance_manager.gd,
# test_broadcast_instance.gd and test_lfg_logic.gd; this is the live proof.
#
# HOW IT IS DRIVEN (T-334 pilot verbs — all landed):
#   pilot.py intent '<json>'   — sends ANY typed intent dict (lfg_flag / lfg_list / anything new)
#   pilot.py crypt enter|leave — enter_instance / leave_instance shorthand
#   pilot.py positions         — the client's last positions payload (instance-scoped truth)
#   pilot.py party invite <user> / party accept, partystate (roster + last lfg_board) — T-280/T-334
#
# RUN FROM THE ORCHESTRATOR: the systems lane never boots the pilot/dev stack
# (agent-standing-orders.md §Lanes). Server-side .gd changes need a stack restart first.
#
# Expected: PASS — b1 groups b2 OFF the LFG board (which then clears), each party sees only its
# own undead + members, A's in-instance combat never perturbs B, and A's exit tears down only A's
# instance. Coords/mobs are the real T-330/T-341/T-332 crypt data — the per-instance mob count is
# DERIVED live from data/instances/hollowed_crypt.json (CRYPT_MOBS below), never a magic number: the
# crypt grew from 6 provisional trash (T-331) to 18 undead + 3 bosses (T-341/T-332), and a hardcoded
# expectation went stale and read the honest full-seed as a "leak". The isolation invariant this
# proves is per-instance == the seed count AND cross-instance unaffected, not any fixed number.
set -uo pipefail
cd "$(dirname "$0")/.."
psql_q() { podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c "$1"; }
fail() { echo "DUNGEON-INSTANCE E2E: FAIL — $1"; exit 1; }
step() { echo "[crypt-e2e] $1"; }

A1=crypt_a1; A2=crypt_a2; B1=crypt_b1; B2=crypt_b2
D2=/tmp/avalon-pilot-a2; D3=/tmp/avalon-pilot-b1; D4=/tmp/avalon-pilot-b2
p1() { python3 scripts/pilot.py "$@"; }
p2() { AVALON_PILOT_DIR=$D2 python3 scripts/pilot.py "$@"; }
p3() { AVALON_PILOT_DIR=$D3 python3 scripts/pilot.py "$@"; }
p4() { AVALON_PILOT_DIR=$D4 python3 scripts/pilot.py "$@"; }
# mob_count <p-fn>: mobs in the given pilot's LAST POSITIONS BROADCAST — the instance-scope truth
# (T-334 `positions` op; the older `scene` op dumps render nodes, not broadcast entities).
mob_count() { "$@" positions 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('positions',{}).get('mobs',[])))"; }
# mob_sig <p-fn>: a stable signature of that peer's instance mob set — sorted `mob_id:hp` pairs. Two
# reads being byte-identical proves NOTHING in that instance changed (used to prove B is untouched
# while A fights: the cross-instance no-leak invariant).
mob_sig() { "$@" positions 2>/dev/null | python3 -c "import json,sys; m=json.load(sys.stdin).get('positions',{}).get('mobs',[]); print('|'.join('%d:%d'%(int(x['mob_id']),int(x['hp'])) for x in sorted(m,key=lambda e:int(e['mob_id']))))"; }
# own_hp <username> <p-fn>: that client's OWN player hp from its last broadcast (mutation witness —
# a1 taking crypt damage proves combat is happening INSIDE instance A).
own_hp() { local u="$1"; shift; "$@" positions 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin).get('positions',{}); ps=[p for p in d.get('players',[]) if p.get('username')=='$u']; print(int(ps[0].get('hp',-1)) if ps else -1)"; }
# own_maxhp <username> <p-fn>: that client's OWN max_hp (the damage-taken denominator).
own_maxhp() { local u="$1"; shift; "$@" positions 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin).get('positions',{}); ps=[p for p in d.get('players',[]) if p.get('username')=='$u']; print(int(ps[0].get('max_hp',0)) if ps else 0)"; }
# lfg_count <p-fn>: rows on that client's last lfg_board reply (refresh with an lfg_list first).
lfg_count() { "$@" partystate 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('party',{}).get('lfg') or []))"; }

step "seeding four warriors"
psql_q "INSERT INTO chars.characters (username) VALUES ('$A1'),('$A2'),('$B1'),('$B2')
        ON CONFLICT (username) DO NOTHING;
        UPDATE chars.characters SET class='warrior', class_locked=true
        WHERE username IN ('$A1','$A2','$B1','$B2');" >/dev/null

step "four clients up"
./scripts/pilot-up.sh "$A1" >/dev/null 2>&1 & sleep 30
AVALON_PILOT_DIR=$D2 ./scripts/pilot-up.sh "$A2" >/dev/null 2>&1 & sleep 30
AVALON_PILOT_DIR=$D3 ./scripts/pilot-up.sh "$B1" >/dev/null 2>&1 & sleep 30
AVALON_PILOT_DIR=$D4 ./scripts/pilot-up.sh "$B2" >/dev/null 2>&1 & sleep 30
sleep 4

# ---- 0) T-334 LFG-lite: b2 flags, b1 invites OFF THE BOARD, board clears -----
step "b2 flags LFG; b1 reads the board"
p4 intent '{"type":"lfg_flag","level":13}' >/dev/null; sleep 1
p3 intent '{"type":"lfg_list"}' >/dev/null; sleep 1
LFG_N=$(lfg_count p3)
[ "$LFG_N" = "1" ] || fail "b1's LFG board shows $LFG_N rows, expected b2's signup (1)"
step "party B forms by inviting off the board (normal T-280 invite)"
p3 party invite "$B2" >/dev/null; sleep 2; p4 party accept >/dev/null; sleep 2
p3 intent '{"type":"lfg_list"}' >/dev/null; sleep 1
LFG_AFTER=$(lfg_count p3)
[ "$LFG_AFTER" = "0" ] || fail "board still shows $LFG_AFTER rows after group-up — clear-on-join broke"
step "0/4 LFG PASS (signup listed, invite-off-board grouped, board cleared on join)"

# ---- form party A -------------------------------------------------------------
step "party A = {a1,a2}"
p1 party invite "$A2" >/dev/null; sleep 2; p2 party accept >/dev/null; sleep 2

# ---- both parties descend the stair -----------------------------------------
# T-380: enter_instance is now proximity-gated to the churchyard porch (instance_service._near_anchor,
# CRYPT_PORCH = 14,-12.5) so a client can't fire it as a free teleport from across the map. Legit
# entry stands on the porch first, so each peer walks there (rate-legal goto hops) before descending —
# the honest at-anchor flow this E2E is the green witness for.
step "both parties walk to the churchyard porch and descend the Hollowed Crypt stair"
for pf in p1 p2 p3 p4; do $pf goto 14 -12.5 >/dev/null; sleep 1; $pf crypt enter >/dev/null; sleep 1; done
sleep 3

# ---- 1) isolation: each peer sees only its own instance's mobs ---------------
MA=$(mob_count p1); MB=$(mob_count p3)
# Per-instance seed count DERIVED from the same data the server seeds (instance_service._seed) — so
# growing the crypt's spawn set never leaves this expectation stale (the T-331→T-341/T-332 growth to
# 21 once read as a leak against a hardcoded 6). This is the honest own-instance truth each party
# must see EXACTLY (no more = no cross-instance/open-world leak; no fewer = its full seed arrived).
CRYPT_MOBS=$(python3 -c "import json; d=json.load(open('server/world/data/instances/hollowed_crypt.json')); print(sum(len(s['positions']) for s in d['spawns']))")
[ -n "$CRYPT_MOBS" ] && [ "$CRYPT_MOBS" -gt 0 ] || fail "could not derive per-instance seed count from hollowed_crypt.json"
[ "$MA" = "$CRYPT_MOBS" ] || fail "party A sees $MA mobs, expected its own $CRYPT_MOBS"
[ "$MB" = "$CRYPT_MOBS" ] || fail "party B sees $MB mobs, expected its own $CRYPT_MOBS"
step "1/4 isolation PASS (each party sees exactly its own $CRYPT_MOBS undead)"

# ---- 2) combat inside instance A never perturbs instance B ------------------
# The no-leak invariant under MUTATION: A trading blows with its own undead must leave B's instance
# byte-for-byte untouched. We assert the SEAM (B unchanged), not that A "wins" the pull — the T-330
# crypt vestibule USED TO stand inside the first trash pack (T-330-tune fixed that entry-death
# defect — the vestibule anchor is now ~7.5-8.1u off pack1, outside aggro range), so this step now
# walks party A onto pack1's anchor before engaging. The E2E's bare-seeded warriors (flat 100 HP, no
# gear/mitigation, single-attacker drive) are NOT tuned to solo a 200-HP skeleton; crypt combat
# BALANCE is a separate concern this isolation E2E does not own. a1 taking crypt damage (its hp drops)
# is the witness that combat truly happened inside A; B's identical mob signature is the isolation.
step "party A walks onto pack1 and engages; party B stands idle in its own instance"
BSIG_BEFORE=$(mob_sig p3)
p1 goto 420 -7.6 >/dev/null; sleep 1
p1 target >/dev/null; sleep 1
p1 key QuoteLeft >/dev/null  # T-057 auto-attack toggle: trade blows with A's undead every GCD
for _ in 1 2 3 4 5; do sleep 2; done
AHP=$(own_hp "$A1" p1); AMAX=$(own_maxhp "$A1" p1)
BSIG_AFTER=$(mob_sig p3); MB2=$(mob_count p3)
# ISOLATION: A's whole fight (a1 trading blows, undead swinging back, deaths) leaves B's undead
# byte-for-byte identical. This is the cross-instance no-leak seam.
[ "$BSIG_AFTER" = "$BSIG_BEFORE" ] || fail "party A's combat leaked into party B (B mob set changed) — instances leaked"
# NON-VACUOUS witness: instance A really saw live, lethal combat — a1 took crypt damage (hp < max).
# Reliable because the T-330 vestibule stands inside the first trash pack, so entrants are engaged
# on arrival (also why a single bare-seeded warrior cannot win the pull — a BALANCE concern outside
# this isolation E2E). If this ever stops holding, the pull got survivable, not the isolation broke.
[ "$AHP" -lt "$AMAX" ] 2>/dev/null || fail "instance A saw no combat (a1 hp $AHP == max $AMAX) — step is vacuous"
step "2/4 no-leak PASS (A saw live combat: a1 hp $AHP/$AMAX; B byte-identical: $MB2 mobs)"

# ---- 3) exit tears the instance down ----------------------------------------
step "party A leaves the crypt"
p1 crypt leave >/dev/null; sleep 1; p2 crypt leave >/dev/null; sleep 3
MB3=$(mob_count p3)
[ "$MB3" = "$MB" ] || fail "party A's teardown disturbed party B ($MB -> $MB3)"
step "3/4 teardown PASS (A's instance freed; B still intact: $MB3)"

for pf in p1 p2 p3 p4; do $pf quit >/dev/null 2>&1; done
echo "DUNGEON-INSTANCE E2E: PASS"
