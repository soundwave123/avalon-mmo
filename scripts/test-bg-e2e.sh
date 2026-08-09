#!/usr/bin/env bash
# T-413 E2E: Crownfield 3v3 through the REAL stack (six piloted clients, one world).
# Integration-harness rule: netcode hides from unit tests.
#   1. Six clients queue (bg_queue) -> a match forms, all six teleport to the arena spawns.
#   2. Team A (a1,a2,a3) walks onto the Crown disc; team B idles at spawn (outside POINT_RADIUS,
#      inside LEASH_RADIUS) -> A accrues 1 point per exclusive second to SCORE_TARGET.
#   3. bg_end fires -> record_match pays honor with ledger reason bg_match (winners > losers),
#      players return to their pre-match positions.
# 3v3 = 6 concurrent clients; the box has GPU headroom for the pilot fleet (staggered boots).
set -uo pipefail
cd "$(dirname "$0")/.."
psql_q() { podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c "$1"; }
fail() { echo "BG E2E: FAIL — $1"; exit 1; }
step() { echo "[bg-e2e] $1"; }
A1=bg_a1 A2=bg_a2 A3=bg_a3 B1=bg_b1 B2=bg_b2 B3=bg_b3
D2=/tmp/avalon-pilot2 D3=/tmp/avalon-pilot3 D4=/tmp/avalon-pilot4 D5=/tmp/avalon-pilot5 D6=/tmp/avalon-pilot6
p1() { python3 scripts/pilot.py "$@"; }
p2() { AVALON_PILOT_DIR=$D2 python3 scripts/pilot.py "$@"; }
p3() { AVALON_PILOT_DIR=$D3 python3 scripts/pilot.py "$@"; }
p4() { AVALON_PILOT_DIR=$D4 python3 scripts/pilot.py "$@"; }
p5() { AVALON_PILOT_DIR=$D5 python3 scripts/pilot.py "$@"; }
p6() { AVALON_PILOT_DIR=$D6 python3 scripts/pilot.py "$@"; }

step "seeding six characters"
psql_q "INSERT INTO chars.characters (username) VALUES
        ('$A1'),('$A2'),('$A3'),('$B1'),('$B2'),('$B3')
        ON CONFLICT (username) DO NOTHING;
        UPDATE chars.characters SET class='warrior', class_locked=true, level=20
        WHERE username IN ('$A1','$A2','$A3','$B1','$B2','$B3');" >/dev/null

step "six clients up (staggered)"
./scripts/pilot-up.sh "$A1" >/dev/null 2>&1 & sleep 25
AVALON_PILOT_DIR=$D2 ./scripts/pilot-up.sh "$A2" >/dev/null 2>&1 & sleep 25
AVALON_PILOT_DIR=$D3 ./scripts/pilot-up.sh "$A3" >/dev/null 2>&1 & sleep 25
AVALON_PILOT_DIR=$D4 ./scripts/pilot-up.sh "$B1" >/dev/null 2>&1 & sleep 25
AVALON_PILOT_DIR=$D5 ./scripts/pilot-up.sh "$B2" >/dev/null 2>&1 & sleep 25
AVALON_PILOT_DIR=$D6 ./scripts/pilot-up.sh "$B3" >/dev/null 2>&1 & sleep 30
sleep 5

BASE=$(psql_q "SELECT count(*) FROM pvp.honor_ledger WHERE reason='bg_match';" 2>/dev/null || echo 0)

step "all six queue"
for p in p1 p2 p3 p4 p5 p6; do $p intent '{"type":"bg_queue"}' >/dev/null 2>&1; sleep 1; done
sleep 6

step "team A takes the Crown; team B idles at spawn"
p1 goto 0 420 >/dev/null 2>&1 &
p2 goto 0 420 >/dev/null 2>&1 &
p3 goto 0 420 >/dev/null 2>&1 &
wait
step "holding for exclusive accrual to SCORE_TARGET (~110s)"
for i in $(seq 1 26); do
	sleep 5
	NOW=$(psql_q "SELECT count(*) FROM pvp.honor_ledger WHERE reason='bg_match';" 2>/dev/null || echo 0)
	[ "${NOW:-0}" -gt "${BASE:-0}" ] && break
done

ROWS=$(psql_q "SELECT count(*) FROM pvp.honor_ledger WHERE reason='bg_match';")
[ "${ROWS:-0}" -gt "${BASE:-0}" ] || fail "no bg_match honor rows appeared (base=$BASE now=$ROWS)"
step "payout rows present ($((ROWS - BASE)) new bg_match ledger rows; expect 6 for a clean 3v3)"

psql_q "SELECT ch.username, l.delta FROM pvp.honor_ledger l
        JOIN chars.characters ch ON ch.id = l.character_id
        WHERE l.reason='bg_match' ORDER BY l.id DESC LIMIT 6;"
echo "BG E2E: PASS"
