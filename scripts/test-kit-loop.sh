#!/usr/bin/env bash
# test-kit-loop.sh — T-063: prove the new class-kit verbs over real ENet (the T-047 pattern).
#   Warrior taunts the dummy (mob 1001) -> ability_result outcome "taunt".
#   Priest self-heals -> ability_result outcome "heal".
# T-068: cast-at-mob legs — every cast-time class ability must LAND on mob 1001 at completion
#   (Holy Fire 304, Smite 303, Frostbolt 204 one cast each from spawn range; Fireball 201
#   repeats until the mob dies -> mob_death broadcast over the wire).
# Seeds a warrior + a priest + a mage character so the server class-gates + resources are real.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
WORLD_DIR="$PROJECT_DIR/server/world"
GODOT="org.godotengine.Godot"
log() { echo "[test-kit-loop] $*"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then set -a; source "$PROJECT_DIR/.env"; set +a; fi
if [[ -z "${AVALON_JWT_SECRET:-}" ]]; then log "FATAL: AVALON_JWT_SECRET not set (.env missing?)"; exit 1; fi
export AVALON_JWT_SECRET
export AVALON_JWT_REFRESH_SECRET="${AVALON_JWT_REFRESH_SECRET:-}"
export AVALON_PG_PASSWORD="${AVALON_PG_PASSWORD:-}"

servers_up() { ss -ulnp 2>/dev/null | grep -q ":9200" && ss -tlnp 2>/dev/null | grep -q ":9100"; }
_started=false
cleanup() { [[ "$_started" == true ]] && bash scripts/dev-down.sh >/dev/null 2>&1; }
trap cleanup EXIT
if servers_up; then log "Using existing servers"; else log "Starting servers..."; bash scripts/dev-up.sh >/dev/null 2>&1; _started=true; sleep 4; fi
servers_up || { log "FATAL: servers not ready on 9100/9200"; exit 1; }

log "Seeding a warrior + a priest (sessions + characters)..."
python3 - << 'PYEOF'
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
toks = {}
for user, cls in [("kit_warrior","warrior"), ("kit_priest","priest"), ("kit_mage","mage")]:
    t = jwt(user); toks[user] = t
    psql("INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked) VALUES ('"+t+"','"+user+"',NOW(),NOW()+INTERVAL '1 hour',false) ON CONFLICT (token) DO UPDATE SET username='"+user+"', revoked=false;")
    psql("INSERT INTO chars.characters (username, class) VALUES ('"+user+"','"+cls+"') ON CONFLICT (username) DO UPDATE SET class='"+cls+"';")
open("/tmp/avalon-kit-tokens.env","w").write("TOKEN_WARRIOR="+toks["kit_warrior"]+"\nTOKEN_PRIEST="+toks["kit_priest"]+"\nTOKEN_MAGE="+toks["kit_mage"]+"\n")
PYEOF
[[ -f /tmp/avalon-kit-tokens.env ]] || { log "FATAL: seed failed"; exit 1; }
source /tmp/avalon-kit-tokens.env

run_kit() { # token result log ability_id target_self move [repeat] [gap_ms] [x] [y]
	local token="$1" result="$2" logf="$3" aid="$4" self="$5" move="$6"
	local repeat="${7:-3}" gap="${8:-700}" tx="${9:-10}" ty="${10:-10}"
	rm -f "$result" "$logf"
	timeout 90 flatpak run \
		--env="AVALON_ABILITY_TARGET_X=$tx" --env="AVALON_ABILITY_TARGET_Y=$ty" \
		--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=9200" \
		--env="AVALON_TOKEN=$token" --env="AVALON_RESULT_FILE=$result" \
		--env="AVALON_USE_ABILITY=1" --env="AVALON_ABILITY_ID=$aid" \
		--env="AVALON_ABILITY_TARGET=1001" --env="AVALON_ABILITY_TARGET_SELF=$self" \
		--env="AVALON_ABILITY_REPEAT=$repeat" --env="AVALON_ABILITY_GAP_MS=$gap" \
		--env="AVALON_ABILITY_MOVE_TO_TARGET=$move" \
		--filesystem="$PROJECT_DIR" --filesystem=/tmp \
		"$GODOT" --headless --path "$WORLD_DIR" --scene res://tests/test_client.tscn > "$logf" 2>&1
}

log "Warrior taunt vs dummy 1001 (ability 102)..."
run_kit "$TOKEN_WARRIOR" /tmp/avalon-kit-taunt.json /tmp/avalon-kit-taunt.log 102 0 1
sleep 1
log "Priest self-heal (ability 301)..."
run_kit "$TOKEN_PRIEST" /tmp/avalon-kit-heal.json /tmp/avalon-kit-heal.log 301 1 0
sleep 1

# T-068: cast-at-mob legs. Casters move to (-5,-5): ~21 units from the dummy's spawn —
# inside the 30-unit cast range but OUTSIDE the 15-unit leash, so the T-070 threat pull
# can't drag the mob onto the caster (chase/pushback/evade-heal would poison the timing).
# One cast per probe leg keeps the dummy (100 hp) alive until the Fireball kill leg.
log "Priest Holy Fire cast vs dummy 1001 (ability 304)..."
run_kit "$TOKEN_PRIEST" /tmp/avalon-kit-holyfire.json /tmp/avalon-kit-holyfire.log 304 0 1 1 6000 -5 -5
sleep 1
log "Priest Smite cast vs dummy 1001 (ability 303)..."
run_kit "$TOKEN_PRIEST" /tmp/avalon-kit-smite.json /tmp/avalon-kit-smite.log 303 0 1 1 6000 -5 -5
sleep 1
log "Mage Frostbolt cast vs dummy 1001 (ability 204)..."
run_kit "$TOKEN_MAGE" /tmp/avalon-kit-frostbolt.json /tmp/avalon-kit-frostbolt.log 204 0 1 1 6000 -5 -5
sleep 1
log "Mage Fireball cast loop vs dummy 1001 (ability 201) until mob_death..."
run_kit "$TOKEN_MAGE" /tmp/avalon-kit-fireball.json /tmp/avalon-kit-fireball.log 201 0 1 12 4000 -5 -5

python3 - << 'PYEOF'
import json
def load(f):
    try: return json.load(open(f))
    except Exception: return {}
def outcomes(d):
    return [r.get("outcome","") for r in d.get("results_received", [])]
def landed(d):  # at least one server-emitted damage result on mob 1001
    return any(
        r.get("type") == "ability_result" and int(r.get("target_id",-1)) == 1001
        and int(r.get("damage",0)) > 0
        for r in d.get("results_received", [])
    )
taunt = outcomes(load("/tmp/avalon-kit-taunt.json"))
heal = outcomes(load("/tmp/avalon-kit-heal.json"))
casts = {name: load("/tmp/avalon-kit-%s.json" % name)
         for name in ("holyfire","smite","frostbolt","fireball")}
print("[test-kit-loop] taunt outcomes:", taunt)
print("[test-kit-loop] heal outcomes:", heal)
errors = []
if "taunt" not in taunt: errors.append("taunt did not resolve")
if "heal" not in heal: errors.append("heal did not resolve")
for name, d in casts.items():
    print("[test-kit-loop] %s: landed=%s cancel_reasons=%s outcomes=%s"
          % (name, landed(d), d.get("cast_cancel_reasons"), outcomes(d)))
    if not landed(d):
        errors.append("%s cast never landed damage on mob 1001" % name)
if not casts["fireball"].get("mob_killed"):
    errors.append("fireball loop did not kill the mob (no mob_death broadcast)")
if errors:
    print("[test-kit-loop] FAIL — " + "; ".join(errors))
    raise SystemExit(1)
print("[test-kit-loop] PASS — taunt + heal + all four cast-time class abilities land; fireball kill loop broadcast mob_death")
PYEOF
