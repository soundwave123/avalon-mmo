#!/usr/bin/env bash
# T-726 evade-reset repro: do the Shallow Graves bosses reset (HP + threat) when the only threat
# source breaks the leash or wipes?
#
# Boots an ISOLATED world from THIS worktree on :9240 → the LIVE master (:9100) and drives ONE real
# piloted client into the KIND_TRIAL instance. It never touches the shared :9200 stack.
#
# The test character is DB-seeded BEFORE handshake (the world caches combat stats at handshake —
# a post-login UPDATE never applies, the T-719 verification's own trap): a level-11 warrior, which
# is under CRYPT_MIN_LEVEL 12 so instance_service still routes it to KIND_TRIAL, but strong enough
# to chip a 333-HP boss and survive long enough to walk out. This measures the RESET, not balance.
#
# AVALON_DEBUG_INTENTS=1 enables the self-only `debug_kill` intent, which drives the real
# death→respawn cycle for the wipe case.
#
# Verdict is printed by scripts/qa/t726_evade_repro.py: exit 0 = bosses reset (hypothesis refuted),
# 2 = they do not (confirmed), 1 = rig failure.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
export AVALON_GODOT_PIN="${AVALON_GODOT_PIN:-native-4.7}"
GODOT="$SCRIPT_DIR/godot-bin.sh"
LANE_PORT=9240
LANE_OPS_PORT=9246
# Two cases, two characters (the class decides which is measurable):
#   reset    (warrior) — CASE A leash-out + CASE B wipe: does the boss full-reset? [the ticket]
#   safespot (mage)    — CASE C: can he be damaged from OUTSIDE the leash, where the T-025 idle
#                        threat-pull refuses to aggro him? Needs a 30-unit ranged ability.
T726_CASE="${T726_CASE:-reset}"
T726_CLASS="${T726_CLASS:-warrior}"
USER_NAME="${T726_USER:-t726pilot}"
PILOT_DIR=/tmp/avalon-pilot-$USER_NAME
WORLD_LOG=/tmp/t726-lane-world-$USER_NAME.log
XP_L11=5500  # leveling.total_xp_for_level(11) = 50*10*11 — under CRYPT_MIN_LEVEL 12
log() { echo "[t726-e2e] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1" >/dev/null 2>&1; }

ss -ltn 2>/dev/null | grep -q ":9100" || { log "FATAL: live master not on :9100"; exit 1; }
[[ -f "$PROJECT_DIR/.env" ]] && { set -a; source "$PROJECT_DIR/.env"; set +a; }
# A lane worktree has no .env of its own — fall back to the checkout that does (T-699 lane idiom).
[[ -z "${AVALON_JWT_SECRET:-}" && -f /home/soundwave/avalon/.env ]] && {
	set -a; source /home/soundwave/avalon/.env; set +a; }
[[ -z "${AVALON_JWT_SECRET:-}" ]] && { log "FATAL: AVALON_JWT_SECRET unset"; exit 1; }

cleanup() {
	[[ -n "${CLIENT_PID:-}" ]] && kill "$CLIENT_PID" 2>/dev/null
	[[ -n "${WORLD_PID:-}" ]] && kill "$WORLD_PID" 2>/dev/null
	pkill -f "AVALON_PORT=$LANE_PORT" 2>/dev/null
	return 0
}
trap cleanup EXIT

TOKEN="$(python3 - "$USER_NAME" <<'PY'
import base64, hashlib, hmac, json, os, sys, time
s = os.environ["AVALON_JWT_SECRET"]; u = sys.argv[1]
b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
h = b(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
p = b(json.dumps({"sub": u, "iat": int(time.time()), "exp": int(time.time()) + 7200, "iss": "avalon"}, separators=(",", ":")).encode())
print(h + "." + p + "." + hmac.new(s.encode(), (h + "." + p).encode(), hashlib.sha256).hexdigest())
PY
)"

log "importing + booting lane world on :$LANE_PORT → live master :9100"
"$GODOT" --headless --path "$PROJECT_DIR/server/world" --import >/dev/null 2>&1
"$GODOT" --headless --path "$PROJECT_DIR/client" --import >/dev/null 2>&1
AVALON_PORT=$LANE_PORT "$GODOT" \
	--env="AVALON_JWT_SECRET=${AVALON_JWT_SECRET}" \
	--env="AVALON_PG_PASSWORD=${AVALON_PG_PASSWORD:-}" \
	--env="AVALON_PORT=$LANE_PORT" --env="AVALON_MASTER_HOST=127.0.0.1" \
	--env="AVALON_MASTER_PORT=9100" --env="AVALON_SPAWN_FIXED=1" \
	--env="AVALON_OPS_PORT=$LANE_OPS_PORT" --env="AVALON_DEBUG_INTENTS=1" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/server/world" --scene res://scenes/main.tscn >"$WORLD_LOG" 2>&1 &
WORLD_PID=$!
for _ in $(seq 1 40); do
	grep -q "listening on enet://0.0.0.0:$LANE_PORT" "$WORLD_LOG" 2>/dev/null && break
	sleep 1
done
grep -q "listening on enet://0.0.0.0:$LANE_PORT" "$WORLD_LOG" || {
	log "FATAL: lane world never bound :$LANE_PORT"; tail -20 "$WORLD_LOG"; exit 1; }
log "lane world up"

psql_exec "INSERT INTO auth.sessions (token,username,issued_at,expires_at,revoked)
	VALUES ('$TOKEN','$USER_NAME',NOW(),NOW()+INTERVAL '2 hours',false)
	ON CONFLICT (token) DO UPDATE SET username='$USER_NAME',revoked=false;"
# Seeded BEFORE the client connects: the world caches combat stats at handshake, so a level set
# after login silently never applies (the T-719 verification lost two runs to exactly that).
psql_exec "INSERT INTO chars.characters (username, name, slot, name_chosen)
	SELECT '$USER_NAME','$USER_NAME',0,true WHERE NOT EXISTS (
		SELECT 1 FROM chars.characters
		WHERE (username='$USER_NAME' OR name='$USER_NAME') AND deleted_at IS NULL);"
psql_exec "UPDATE chars.characters SET class='$T726_CLASS', class_locked=true, gender='male',
	name_chosen=true, xp=$XP_L11, level=11 WHERE username='$USER_NAME' AND deleted_at IS NULL;"

rm -rf "$PILOT_DIR"; mkdir -p "$PILOT_DIR"
# AVALON_OBSERVE=1 is REQUIRED, not decoration: main.gd quits a headless client the moment the
# world is ready unless observe mode is on (T-729 lesson).
log "launching piloted headless client → :$LANE_PORT"
"$GODOT" \
	--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=$LANE_PORT" --env="AVALON_TOKEN=$TOKEN" \
	--env="AVALON_PILOT=1" --env="AVALON_PILOT_DIR=$PILOT_DIR" \
	--env="AVALON_COMBAT_TRACE=1" \
	--env="AVALON_OBSERVE=1" --env="AVALON_OBSERVE_SECS=900" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/client" --scene res://scenes/main.tscn \
	>"$PILOT_DIR/client.log" 2>&1 &
CLIENT_PID=$!
for _ in $(seq 1 40); do
	grep -q "\[pilot\] active" "$PILOT_DIR/client.log" 2>/dev/null && break
	sleep 1
done
grep -q "\[pilot\] active" "$PILOT_DIR/client.log" || {
	log "FATAL: pilot never came up"; tail -20 "$PILOT_DIR/client.log"; exit 1; }
log "pilot active — running case '$T726_CASE' ($T726_CLASS) against Pallbearer Ost"

AVALON_PILOT_DIR="$PILOT_DIR" python3 "$SCRIPT_DIR/qa/t726_evade_repro.py" "$T726_CASE" "$T726_CLASS"
RC=$?
log "--- world log: instance + evade-relevant lines ---"
grep -E "\[instance\]|\[boss\]|evad|leash|trial" "$WORLD_LOG" | tail -25
case $RC in
	0) log "VERDICT: bosses RESET — T-726 hypothesis REFUTED" ;;
	2) log "VERDICT: bosses DO NOT RESET — T-726 hypothesis CONFIRMED" ;;
	*) log "RIG FAILURE (rc=$RC)"
	   log "--- client log tail ---"; tail -20 "$PILOT_DIR/client.log"
	   log "--- world log tail ---"; tail -20 "$WORLD_LOG" ;;
esac
exit $RC
