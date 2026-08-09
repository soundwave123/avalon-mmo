#!/usr/bin/env bash
# test-talent-loop.sh — T-064: server-validated talent spends over real ENet.
#   Leg A: tier-2 talent with an empty tree -> rejected "tier_locked".
#   Leg B: L4 mage (3 points) spends Improved Fireball x4 -> ranks 1,2,3 then a
#          rejection (out of points); final state shows 3/3 spent.
#   Leg C: reconnect -> ranks persisted (3) with zero new spends.
#   Leg D: fresh character picks a class ONCE (mage ok, then warrior -> class_locked);
#          the talents reply then carries MAGE tree defs only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
WORLD_DIR="$PROJECT_DIR/server/world"
GODOT="org.godotengine.Godot"
log() { echo "[test-talent-loop] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then set -a; source "$PROJECT_DIR/.env"; set +a; fi
if [[ -z "${AVALON_JWT_SECRET:-}" ]]; then log "FATAL: AVALON_JWT_SECRET not set"; exit 1; fi
export AVALON_JWT_SECRET
export AVALON_JWT_REFRESH_SECRET="${AVALON_JWT_REFRESH_SECRET:-}"
export AVALON_PG_PASSWORD="${AVALON_PG_PASSWORD:-}"

servers_up() { ss -ulnp 2>/dev/null | grep -q ":9200" && ss -tlnp 2>/dev/null | grep -q ":9100"; }
_started=false
cleanup() { [[ "$_started" == true ]] && bash scripts/dev-down.sh >/dev/null 2>&1; }
trap cleanup EXIT
if servers_up; then log "Using existing servers"; else log "Starting servers..."; bash scripts/dev-up.sh >/dev/null 2>&1; _started=true; sleep 4; fi
servers_up || { log "FATAL: servers not ready"; exit 1; }

USER="talent_mage"
log "Seeding L4 mage '$USER' with a clean talent sheet..."
TOKEN=$(python3 - << SEED_EOF
import base64, hashlib, hmac, json, os, subprocess, time
secret = os.environ["AVALON_JWT_SECRET"]
def b64(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
h = b64(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(",",":")).encode())
p = b64(json.dumps({"sub":"$USER","iat":int(time.time()),"exp":int(time.time())+3600,"iss":"avalon"}, separators=(",",":")).encode())
s = hmac.new(secret.encode(), (h+"."+p).encode(), hashlib.sha256).hexdigest()
t = h+"."+p+"."+s
sql = ("INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked) VALUES ('"+t+"','$USER',NOW(),NOW()+INTERVAL '1 hour',false) ON CONFLICT (token) DO UPDATE SET username='$USER', revoked=false;")
subprocess.run(["bash","-c","podman exec avalon-postgres psql -U avalon -d avalon -c \""+sql+"\""], check=True, capture_output=True)
print(t)
SEED_EOF
)
psql_exec "INSERT INTO chars.characters (username, class, level) VALUES ('$USER','mage',4)
	ON CONFLICT (username) DO UPDATE SET class='mage', level=4;" >/dev/null 2>&1
psql_exec "DELETE FROM chars.character_talents WHERE character_id
	IN (SELECT id FROM chars.characters WHERE username='$USER');" >/dev/null 2>&1

run_leg() { # talent_id spends result_file log_file [token] [set_class_csv]
	local talent="$1" spends="$2" result="$3" logf="$4"
	local token="${5:-$TOKEN}" set_class="${6:-}"
	rm -f "$result" "$logf"
	timeout 90 flatpak run \
		--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=9200" \
		--env="AVALON_TOKEN=$token" --env="AVALON_RESULT_FILE=$result" \
		--env="AVALON_TALENT_MODE=1" --env="AVALON_TALENT_ID=$talent" \
		--env="AVALON_TALENT_SPENDS=$spends" --env="AVALON_SET_CLASS=$set_class" \
		--filesystem="$PROJECT_DIR" --filesystem=/tmp \
		"$GODOT" --headless --path "$WORLD_DIR" --scene res://tests/test_client.tscn > "$logf" 2>&1
}

log "Leg A: tier-2 Pyromania with an empty tree (expect tier_locked)..."
run_leg tal_mag_pyromania 1 /tmp/avalon-talent-a.json /tmp/avalon-talent-a.log
sleep 1
log "Leg B: Improved Fireball x4 with 3 points (expect 3 ok + 1 reject)..."
run_leg tal_mag_imp_fireball 4 /tmp/avalon-talent-b.json /tmp/avalon-talent-b.log
sleep 1
log "Leg C: reconnect, zero spends (expect persisted ranks=3)..."
run_leg tal_mag_imp_fireball 0 /tmp/avalon-talent-c.json /tmp/avalon-talent-c.log
sleep 1
FRESH="talent_fresh"
log "Leg D: fresh character '$FRESH' picks mage once, then warrior (expect class_locked)..."
FRESH_TOKEN=$(python3 - << SEED2_EOF
import base64, hashlib, hmac, json, os, subprocess, time
secret = os.environ["AVALON_JWT_SECRET"]
def b64(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
h = b64(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(",",":")).encode())
p = b64(json.dumps({"sub":"$FRESH","iat":int(time.time()),"exp":int(time.time())+3600,"iss":"avalon"}, separators=(",",":")).encode())
s = hmac.new(secret.encode(), (h+"."+p).encode(), hashlib.sha256).hexdigest()
t = h+"."+p+"."+s
sql = ("INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked) VALUES ('"+t+"','$FRESH',NOW(),NOW()+INTERVAL '1 hour',false) ON CONFLICT (token) DO UPDATE SET username='$FRESH', revoked=false;")
subprocess.run(["bash","-c","podman exec avalon-postgres psql -U avalon -d avalon -c \""+sql+"\""], check=True, capture_output=True)
print(t)
SEED2_EOF
)
psql_exec "INSERT INTO chars.characters (username, class, level) VALUES ('$FRESH','warrior',1)
	ON CONFLICT (username) DO UPDATE SET class='warrior', level=1, class_locked=false;" >/dev/null 2>&1
run_leg none 0 /tmp/avalon-talent-d.json /tmp/avalon-talent-d.log "$FRESH_TOKEN" "mage,warrior"

python3 << 'PYEOF'
import json
def load(f):
    try: return json.load(open(f))
    except Exception: return {}
a, b, c = (load(f"/tmp/avalon-talent-{x}.json") for x in "abc")
errors = []

a_res = a.get("spend_results", [])
print("[test-talent-loop] A: spends=", [(r.get("ok"), r.get("reason")) for r in a_res])
if not a_res or a_res[0].get("ok") is not False or a_res[0].get("reason") != "tier_locked":
    errors.append(f"A: tier-2 spend with empty tree not tier_locked: {a_res}")

b_res = b.get("spend_results", [])
print("[test-talent-loop] B: spends=", [(r.get("ok"), r.get("reason"), r.get("ranks")) for r in b_res])
print("[test-talent-loop] B: after=", b.get("talents_after"))
oks = [r for r in b_res if r.get("ok")]
rejects = [r for r in b_res if not r.get("ok")]
if len(oks) != 3 or [int(r.get("ranks", 0)) for r in oks] != [1, 2, 3]:
    errors.append(f"B: expected ranks 1,2,3 accepted: {b_res}")
if len(rejects) != 1 or rejects[0].get("reason") not in ("no_points", "max_ranks"):
    errors.append(f"B: 4th spend must be rejected for points/ranks: {rejects}")
after = b.get("talents_after", {})
if int(after.get("talents", {}).get("tal_mag_imp_fireball", 0)) != 3:
    errors.append(f"B: final state must show 3 ranks: {after}")
if int(after.get("points_spent", -1)) != 3 or int(after.get("points_available", -1)) != 3:
    errors.append(f"B: point budget wrong: {after}")

c_after = c.get("talents_after", {})
print("[test-talent-loop] C: after=", c_after)
if int(c_after.get("talents", {}).get("tal_mag_imp_fireball", 0)) != 3:
    errors.append(f"C: ranks did not persist across reconnect: {c_after}")

d = load("/tmp/avalon-talent-d.json")
d_set = d.get("set_class_results", [])
print("[test-talent-loop] D: set_class=", [(r.get("ok"), r.get("reason"), r.get("class")) for r in d_set])
if len(d_set) != 2 or d_set[0].get("ok") is not True or str(d_set[0].get("class")) != "mage":
    errors.append(f"D: first set_class(mage) must succeed: {d_set}")
if len(d_set) == 2 and (d_set[1].get("ok") is not False or d_set[1].get("reason") != "class_locked"):
    errors.append(f"D: second set_class must be class_locked: {d_set}")
d_defs = d.get("talents_after", {}).get("defs", [])
if not d_defs or not all(str(t.get("id", "")).startswith("tal_mag_") for t in d_defs):
    errors.append(f"D: talents reply must carry MAGE tree defs only ({len(d_defs)} defs)")

if errors:
    print("[test-talent-loop] FAIL — " + "; ".join(errors))
    raise SystemExit(1)
print("[test-talent-loop] PASS — tier gate, point budget, rank cap, persistence, and one-shot class selection all enforced server-side over ENet")
PYEOF
