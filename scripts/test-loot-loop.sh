#!/usr/bin/env bash
# test-loot-loop.sh — T-073: the authored quests' kill + collect sources exist LIVE.
#   Leg 1: accept q001, kill a Gray Wolf (1101)      → kill objective credits AND the wolf's
#          pelt drops into the bag (collect objective credits via the loot grant).
#   Leg 2: accept q002, kill a Kobold Miner (1201)   → copper ore + rugged fiber collected.
#   Leg 3: accept q005, kill a Bloodthorn Lasher (1301) → bloodthorn collected.
# Everything asserted is server-emitted (enriched quest log over real ENet).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
WORLD_DIR="$PROJECT_DIR/server/world"
GODOT="org.godotengine.Godot"
log() { echo "[test-loot-loop] $*"; }
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

# One user PER LEG: request_move is a DELTA from the session position, and a reused token
# restores the previous leg's position (T-015) — a fresh user always starts at the origin.
log "Seeding sessions + characters for the three legs..."
python3 - << 'SEED_EOF'
import base64, hashlib, hmac, json, os, subprocess, time
secret = os.environ["AVALON_JWT_SECRET"]
def b64(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
def jwt(sub):
    h = b64(json.dumps({"alg":"HS256","typ":"JWT"}, separators=(",",":")).encode())
    p = b64(json.dumps({"sub":sub,"iat":int(time.time()),"exp":int(time.time())+3600,"iss":"avalon"}, separators=(",",":")).encode())
    s = hmac.new(secret.encode(), (h+"."+p).encode(), hashlib.sha256).hexdigest()
    return h+"."+p+"."+s
def psql(sql):
    subprocess.run(["bash","-c","podman exec -i avalon-postgres psql -U avalon -d avalon -c \""+sql+"\""], check=True, capture_output=True)
lines = []
for user in ("loot_wolf", "loot_kobold", "loot_lasher"):
    t = jwt(user)
    psql("INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked) VALUES ('"+t+"','"+user+"',NOW(),NOW()+INTERVAL '1 hour',false) ON CONFLICT (token) DO UPDATE SET username='"+user+"', revoked=false;")
    psql("INSERT INTO chars.characters (username, class) VALUES ('"+user+"','warrior') ON CONFLICT (username) DO NOTHING;")
    psql("DELETE FROM chars.character_quest_objectives WHERE character_id IN (SELECT id FROM chars.characters WHERE username='"+user+"');")
    psql("DELETE FROM chars.character_quests WHERE character_id IN (SELECT id FROM chars.characters WHERE username='"+user+"');")
    psql("DELETE FROM inventory.character_items WHERE character_id IN (SELECT id FROM chars.characters WHERE username='"+user+"');")
    lines.append("TOKEN_" + user.split("_")[1].upper() + "=" + t)
open("/tmp/avalon-loot-tokens.env","w").write("\n".join(lines) + "\n")
SEED_EOF
[[ -f /tmp/avalon-loot-tokens.env ]] || { log "FATAL: seed failed"; exit 1; }
source /tmp/avalon-loot-tokens.env

run_leg() { # token quest_id target_id x y result_file log_file
	local token="$1" quest="$2" target="$3" tx="$4" ty="$5" result="$6" logf="$7"
	rm -f "$result" "$logf"
	timeout 120 flatpak run \
		--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=9200" \
		--env="AVALON_TOKEN=$token" --env="AVALON_RESULT_FILE=$result" \
		--env="AVALON_QUEST_MODE=1" --env="AVALON_QUEST_ID=$quest" \
		--env="AVALON_ABILITY_ID=1" --env="AVALON_ABILITY_TARGET=$target" \
		--env="AVALON_ABILITY_REPEAT=20" --env="AVALON_ABILITY_GAP_MS=1600" \
		--env="AVALON_ABILITY_MOVE_TO_TARGET=1" \
		--env="AVALON_ABILITY_TARGET_X=$tx" --env="AVALON_ABILITY_TARGET_Y=$ty" \
		--filesystem="$PROJECT_DIR" --filesystem=/tmp \
		"$GODOT" --headless --path "$WORLD_DIR" --scene res://tests/test_client.tscn > "$logf" 2>&1
}

log "Leg 1: q001 — kill Gray Wolf 1101, expect kill credit + pelt loot..."
run_leg "$TOKEN_WOLF" q001 1101 30 20 /tmp/avalon-loot-q001.json /tmp/avalon-loot-q001.log
sleep 1
log "Leg 2: q002 — kill Kobold Miner 1201, expect ore + fiber loot..."
run_leg "$TOKEN_KOBOLD" q002 1201 -20 25 /tmp/avalon-loot-q002.json /tmp/avalon-loot-q002.log
sleep 1
log "Leg 3: q005 — kill Bloodthorn Lasher 1301, expect bloodthorn loot..."
run_leg "$TOKEN_LASHER" q005 1301 -30 -25 /tmp/avalon-loot-q005.json /tmp/avalon-loot-q005.log

python3 - << 'PYEOF'
import json
def load(f):
    try: return json.load(open(f))
    except Exception: return {}
errors = []
def check(name, path, wants):  # wants: [(obj_index, label)]
    d = load(path)
    objs = d.get("quest_objectives", [])
    print(f"[test-loot-loop] {name}: accept_ok={d.get('accept_ok')} mob_killed={d.get('mob_killed')}"
          f" objectives={[(o.get('desc',''), o.get('current')) for o in objs]}")
    if d.get("accept_ok") is not True:
        errors.append(f"{name}: accept failed")
    if d.get("mob_killed") is not True:
        errors.append(f"{name}: mob never died (spawn missing or unkillable)")
    for idx, label in wants:
        if idx >= len(objs) or int(objs[idx].get("current", 0)) < 1:
            errors.append(f"{name}: objective {idx} ({label}) not credited — {objs}")
check("q001-wolf", "/tmp/avalon-loot-q001.json", [(0, "kill mob_wolf"), (1, "collect itm_wolf_pelt")])
check("q002-kobold", "/tmp/avalon-loot-q002.json", [(0, "collect itm_copper_ore"), (1, "collect itm_rugged_fiber")])
check("q005-lasher", "/tmp/avalon-loot-q005.json", [(0, "collect itm_bloodthorn")])
if errors:
    print("[test-loot-loop] FAIL — " + "; ".join(errors))
    raise SystemExit(1)
print("[test-loot-loop] PASS — wolves/kobolds/lashers spawn, die, and drop quest loot; kill + collect objectives credit over ENet")
PYEOF
