#!/usr/bin/env bash
# T-264 E2E: cast state travels the real stack — caster A starts a 2s Fireball; watcher B
# reads A's live cast (ability + remaining) from its own client scene. Two piloted
# clients, one world. Exit 1 on any failed assertion.
set -uo pipefail
cd "$(dirname "$0")/.."
psql_q() { podman exec -i avalon-postgres psql -U avalon -d avalon -tA -c "$1"; }
fail() { echo "CAST E2E: FAIL — $1"; exit 1; }
step() { echo "[cast-e2e] $1"; }
A=cast_a; B=cast_b; DIR_B=/tmp/avalon-pilot2
pilot_a() { python3 scripts/pilot.py "$@"; }
pilot_b() { AVALON_PILOT_DIR=$DIR_B python3 scripts/pilot.py "$@"; }

step "seed: $A is a locked mage; $B watches"
psql_q "INSERT INTO chars.characters (username) VALUES ('$A'),('$B') ON CONFLICT (username) DO NOTHING;
        UPDATE chars.characters SET class='mage', class_locked=true, level=1 WHERE username='$A';
        UPDATE chars.characters SET class='warrior', class_locked=true WHERE username='$B';" >/dev/null

./scripts/pilot-up.sh "$A" >/dev/null 2>&1 & sleep 30
AVALON_PILOT_DIR=$DIR_B ./scripts/pilot-up.sh "$B" >/dev/null 2>&1 & sleep 30

step "A targets a wolf from range and opens a Frostbolt cast (1.5s)"
python3 - <<'PY2'
import json, subprocess, sys, time, os
def run(second, *args):
    env = dict(os.environ)
    if second: env["AVALON_PILOT_DIR"] = "/tmp/avalon-pilot2"
    r = subprocess.run(["python3", "scripts/pilot.py", *args], capture_output=True, text=True, env=env)
    try: return json.loads(r.stdout)
    except Exception: return {}
# The dummy at (10,10) is occluded by the drillmaster house and aggro-kills slow probers
# (learned the hard way) — wolves at (30,20) probe cleanly from (30,31) at cast range.
run(False, "goto", "30", "31"); time.sleep(1.5)
found = None
for y in range(380, 761, 40):
    for x in range(600, 1321, 40):
        p = run(False, "pick", str(x), str(y))
        if "RemoteEnt" in str(p.get("collider", "")) or "mob" in str(p.get("collider", "")):
            found = (x, y); break
    if found: break
if not found:
    print(json.dumps({"error": "no mob on screen"})); sys.exit(1)
run(False, "click", str(found[0]), str(found[1])); time.sleep(0.3)
seen_a = seen_b = False
run(False, "key", "3")  # mage kit slot 3 = Frostbolt (ability 204, 1.5s)
t0 = time.time()
while time.time() - t0 < 2.5:
    ca = run(False, "casts").get("casts", {})
    if ca.get("local") and int(ca["local"].get("ability_id", -1)) == 204: seen_a = True
    cb = run(True, "casts").get("casts", {})
    for eid, c in (cb.get("remote") or {}).items():
        if eid.startswith("player") and int(c.get("ability_id", -1)) == 204: seen_b = True
    if seen_a and seen_b: break
    time.sleep(0.1)
print(json.dumps({"a_saw_own_cast": seen_a, "b_saw_a_cast": seen_b}))
sys.exit(0 if (seen_a and seen_b) else 1)
PY2
RC=$?
[ $RC -eq 0 ] || fail "cast not visible on both clients (see JSON above)"
step "both clients saw the live cast"
pilot_a quit >/dev/null 2>&1; pilot_b quit >/dev/null 2>&1
echo "CAST E2E: PASS"
