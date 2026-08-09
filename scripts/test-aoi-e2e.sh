#!/usr/bin/env bash
# T-370 E2E: the AOI (area-of-interest) broadcast filter through the REAL stack (two piloted
# clients in the open world). Netcode/interest scoping hides from unit tests — the pure filter is
# proven by test_broadcast_aoi.gd; THIS is the live spawn/despawn/re-entry proof the ticket asks
# for. It exercises the exact seam an all-peers broadcast could not: a peer stops receiving another
# peer once it leaves the interest radius, and receives it again on re-entry.
#
# RUN FROM THE ORCHESTRATOR: the systems lane never boots the pilot/dev stack
# (agent-standing-orders.md §Lanes). Server-side .gd changes need a stack restart first so the
# AOI code (broadcast_builder.positions_frames_aoi + ServerConfig AOI radius) is loaded.
#
# Expected: PASS —
#   1) OUT: clients 300 m apart (> 80 m radius) → neither is in the other's positions players list.
#   2) IN:  move them ~30 m apart (< radius) → each now receives the other (remote entity re-spawns).
#   3) RE-EXIT: move apart again → each drops the other (despawn), proving interest is re-evaluated
#      every broadcast, not latched.
# The interest RADIUS is the server's ServerConfig.get_aoi_radius() (default 80 m). Distances below
# are chosen well inside/outside that so the test is robust to the exact value.
set -uo pipefail
cd "$(dirname "$0")/.."
psql_q() { podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c "$1"; }
fail() { echo "AOI E2E: FAIL — $1"; for pf in p1 p2; do $pf quit >/dev/null 2>&1; done; exit 1; }
step() { echo "[aoi-e2e] $1"; }

U1=aoi_alice; U2=aoi_bob
D2=/tmp/avalon-pilot-aoi2
p1() { python3 scripts/pilot.py "$@"; }
p2() { AVALON_PILOT_DIR=$D2 python3 scripts/pilot.py "$@"; }

# sees <other_username> <p-fn>: 1 if <other_username> appears in that client's LAST positions
# broadcast players list (the interest truth — the server only sends players inside AOI), else 0.
sees() {
	local other="$1"
	shift
	"$@" positions 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin).get('positions',{}); print(1 if any(p.get('username')=='$other' for p in d.get('players',[])) else 0)"
}
# nplayers <p-fn>: how many players are in that client's last broadcast (self + in-range peers).
nplayers() { "$@" positions 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('positions',{}).get('players',[])))"; }

step "seeding two warriors"
psql_q "INSERT INTO chars.characters (username) VALUES ('$U1'),('$U2')
        ON CONFLICT (username) DO NOTHING;
        UPDATE chars.characters SET class='warrior', class_locked=true
        WHERE username IN ('$U1','$U2');" >/dev/null

step "two clients up"
./scripts/pilot-up.sh "$U1" >/dev/null 2>&1 & sleep 30
AVALON_PILOT_DIR=$D2 ./scripts/pilot-up.sh "$U2" >/dev/null 2>&1 & sleep 30
sleep 4

# ---- 1) OUT of range: 300 m apart, well beyond the 80 m radius --------------------------------
step "move both clients 300 m apart"
p1 goto -150 0 >/dev/null; sleep 1
p2 goto 150 0 >/dev/null; sleep 2
S12=$(sees "$U2" p1); S21=$(sees "$U1" p2)
N1=$(nplayers p1); N2=$(nplayers p2)
[ "$S12" = "0" ] || fail "alice sees bob at 300 m (AOI filter not applied on the broadcast)"
[ "$S21" = "0" ] || fail "bob sees alice at 300 m (AOI filter not applied on the broadcast)"
step "1/3 OUT PASS (300 m apart: neither peer is in the other's broadcast; players self-only: $N1/$N2)"

# ---- 2) IN range: ~30 m apart, inside the radius → each re-spawns the other -------------------
step "move bob to ~30 m from alice"
p2 goto -150 30 >/dev/null; sleep 2
S12=$(sees "$U2" p1); S21=$(sees "$U1" p2)
[ "$S12" = "1" ] || fail "alice does NOT see bob at 30 m — in-range peer never entered interest"
[ "$S21" = "1" ] || fail "bob does NOT see alice at 30 m — in-range peer never entered interest"
step "2/3 IN PASS (30 m apart: each peer entered the other's interest and re-spawned)"

# ---- 3) RE-EXIT: pull bob back out → interest is re-evaluated, the other despawns -------------
step "move bob back out to 300 m"
p2 goto 150 0 >/dev/null; sleep 2
S12=$(sees "$U2" p1); S21=$(sees "$U1" p2)
[ "$S12" = "0" ] || fail "alice STILL sees bob after he left the radius — interest latched (bug)"
[ "$S21" = "0" ] || fail "bob STILL sees alice after leaving the radius — interest latched (bug)"
step "3/3 RE-EXIT PASS (moved apart again: each peer dropped the other — interest is per-broadcast)"

for pf in p1 p2; do $pf quit >/dev/null 2>&1; done
echo "AOI E2E: PASS"
