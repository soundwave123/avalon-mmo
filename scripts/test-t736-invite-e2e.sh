#!/usr/bin/env bash
# T-736 two-client E2E: the party invite flow over REAL transport — right-click context menu ->
# party_invite -> invitee Accept/Decline modal -> T-280 roster on both clients, plus the
# server-enforced decline cooldown (3 declines from the same inviter to the same target block
# the 4th invite, silently for the decliner).
#
# ISOLATION (T-745 rule): NOTHING live is touched. Own Postgres container on :5434, own master
# on :9135 (AVALON_MASTER_PORT override), own world on :9235 — never 9001/9100/9200/5432, and no
# test rows in the live DB. Both piloted clients run THIS worktree's client code headlessly.
#
# WHAT IT PROVES, in order:
#   1. A right-clicks B's body (pilot `rclick` = real RMB press/release through the T-739
#      deadzone + live ray) -> the context menu opens -> clicking "Invite to Party" sends the
#      intent. B's modal shows ("invite modal shown from A" breadcrumb + partystate pending).
#   2. B clicks Accept (real button) -> BOTH clients' rosters read [A, B], A leads, and A's
#      party frames surface is live (the T-285 render feed).
#   3. B leaves; then B declines three invites via the real Decline button -> A's 4th invite
#      is refused with invite_cooldown (A sees the refusal; B gets NO 4th modal — grief-silent).
#   4. The cooldown is per inviter->target pair: B can still invite A, who accepts (modal path).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
export AVALON_GODOT_PIN="${AVALON_GODOT_PIN:-native-4.7}"
GODOT="$SCRIPT_DIR/godot-bin.sh"

PG_TEST_PORT=5434 # never 5432 (live Postgres)
PG_CONTAINER=avalon-postgres-t736
MASTER_PORT=9135 # never 9100 (live master)
WORLD_PORT=9235  # never 9200 (live world)
OUT_DIR="${AVALON_TEST_LOG_DIR:-/tmp/avalon-tests-t736}"
DIR_A="$OUT_DIR/pilot-a"
DIR_B="$OUT_DIR/pilot-b"
MASTER_LOG="$OUT_DIR/t736-master.log"
WORLD_LOG="$OUT_DIR/t736-world.log"
USER_A=t736a
USER_B=t736b

export AVALON_PG_PASSWORD="t736_isolated_not_the_live_password"
export PG_HOST=127.0.0.1
export PG_PORT="$PG_TEST_PORT"
export PG_USER=avalon
JWT_SECRET="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # dummy, isolated stack only (t740 idiom)

log() { echo "[t736-e2e] $*"; }
RC=0
fail() {
	log "FAIL: $*"
	RC=$((RC + 1)) # count fails so per-phase verdicts stay honest (a bool would mask them)
}
psql_exec() { podman exec -i "$PG_CONTAINER" psql -U avalon -d avalon -q -c "$1" >/dev/null; }

mkdir -p "$OUT_DIR"
rm -rf "$DIR_A" "$DIR_B"
mkdir -p "$DIR_A" "$DIR_B"

cleanup() {
	[[ -n "${CLIENT_A_PID:-}" ]] && kill "$CLIENT_A_PID" 2>/dev/null
	[[ -n "${CLIENT_B_PID:-}" ]] && kill "$CLIENT_B_PID" 2>/dev/null
	[[ -n "${WORLD_PID:-}" ]] && kill "$WORLD_PID" 2>/dev/null
	[[ -n "${MASTER_PID:-}" ]] && kill "$MASTER_PID" 2>/dev/null
	pkill -f "AVALON_PORT=$WORLD_PORT" 2>/dev/null
	pkill -f "AVALON_MASTER_PORT=$MASTER_PORT.*path $PROJECT_DIR/server/master" 2>/dev/null
	podman rm -f "$PG_CONTAINER" >/dev/null 2>&1
	return 0
}
trap cleanup EXIT

for tool in podman python3; do
	command -v "$tool" >/dev/null 2>&1 || {
		log "FATAL: $tool required"
		exit 2
	}
done

# ------------------------------------------------------------------ isolated Postgres on :5434
log "starting isolated Postgres ($PG_CONTAINER) on :$PG_TEST_PORT"
podman rm -f "$PG_CONTAINER" >/dev/null 2>&1
podman run -d --name "$PG_CONTAINER" \
	-p "127.0.0.1:$PG_TEST_PORT:5432" \
	-e POSTGRES_USER=avalon -e POSTGRES_PASSWORD="$AVALON_PG_PASSWORD" -e POSTGRES_DB=avalon \
	docker.io/library/postgres:17-alpine >/dev/null || {
	log "FATAL: podman run failed"
	exit 1
}
for _ in $(seq 1 60); do
	podman exec "$PG_CONTAINER" pg_isready -U avalon -d avalon >/dev/null 2>&1 && break
	sleep 1
done
podman exec "$PG_CONTAINER" pg_isready -U avalon -d avalon >/dev/null 2>&1 || {
	log "FATAL: isolated Postgres never became ready"
	exit 1
}
log "applying init.sql + migrations"
podman exec -i "$PG_CONTAINER" psql -U avalon -d avalon -q -v ON_ERROR_STOP=1 \
	<"$PROJECT_DIR/infra/postgres/init.sql" >/dev/null 2>&1 || {
	log "FATAL: init.sql failed"
	exit 1
}
bash "$SCRIPT_DIR/apply-migrations.sh" >"$OUT_DIR/t736-migrations.log" 2>&1 || {
	log "FATAL: migrations failed"
	tail -20 "$OUT_DIR/t736-migrations.log"
	exit 1
}

# --------------------------------------------------------------- JWTs signed with the TEST secret
mint_jwt() {
	AVALON_JWT_SECRET="$JWT_SECRET" python3 - "$1" <<'PY'
import base64, hashlib, hmac, json, os, sys, time
s = os.environ["AVALON_JWT_SECRET"]; u = sys.argv[1]
b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
h = b(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
p = b(json.dumps({"sub": u, "iat": int(time.time()), "exp": int(time.time()) + 3600, "iss": "avalon"}, separators=(",", ":")).encode())
print(h + "." + p + "." + hmac.new(s.encode(), (h + "." + p).encode(), hashlib.sha256).hexdigest())
PY
}
TOKEN_A="$(mint_jwt $USER_A)"
TOKEN_B="$(mint_jwt $USER_B)"

log "seeding sessions + locked warrior characters (isolated DB only)"
for pair in "$USER_A|$TOKEN_A" "$USER_B|$TOKEN_B"; do
	u="${pair%%|*}"
	t="${pair##*|}"
	psql_exec "INSERT INTO auth.sessions (token,username,issued_at,expires_at,revoked)
		VALUES ('$t','$u',NOW(),NOW()+INTERVAL '1 hour',false);"
	psql_exec "INSERT INTO chars.characters (username,name,slot,class,class_locked,gender,name_chosen)
		VALUES ('$u','$u',0,'warrior',true,'male',true);"
done

# ------------------------------------------------------------------ isolated master on :9135
log "importing projects + booting isolated master on ws://127.0.0.1:$MASTER_PORT"
"$GODOT" --headless --path "$PROJECT_DIR/server/master" --import >/dev/null 2>&1
"$GODOT" --headless --path "$PROJECT_DIR/server/world" --import >/dev/null 2>&1
"$GODOT" --headless --path "$PROJECT_DIR/client" --import >/dev/null 2>&1
AVALON_MASTER_PORT=$MASTER_PORT "$GODOT" \
	--env="AVALON_MASTER_PORT=$MASTER_PORT" \
	--env="AVALON_JWT_SECRET=$JWT_SECRET" \
	--env="AVALON_PG_PASSWORD=$AVALON_PG_PASSWORD" \
	--env="PG_HOST=127.0.0.1" --env="PG_PORT=$PG_TEST_PORT" --env="PG_USER=avalon" \
	--env="AVALON_DB_DRIVER=subprocess" --env="AVALON_DBD_SECRET=" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/server/master" --scene res://scenes/main.tscn \
	>"$MASTER_LOG" 2>&1 &
MASTER_PID=$!
for _ in $(seq 1 40); do
	grep -q "listening on ws://.*:$MASTER_PORT" "$MASTER_LOG" 2>/dev/null && break
	sleep 1
done
grep -q "listening on ws://.*:$MASTER_PORT" "$MASTER_LOG" || {
	log "FATAL: master never bound :$MASTER_PORT"
	tail -20 "$MASTER_LOG"
	exit 1
}
log "master up"

# ------------------------------------------------------------------ isolated world on :9235
log "booting isolated world on enet://:$WORLD_PORT -> master :$MASTER_PORT"
AVALON_PORT=$WORLD_PORT "$GODOT" \
	--env="AVALON_JWT_SECRET=$JWT_SECRET" \
	--env="AVALON_PG_PASSWORD=$AVALON_PG_PASSWORD" \
	--env="PG_HOST=127.0.0.1" --env="PG_PORT=$PG_TEST_PORT" --env="PG_USER=avalon" \
	--env="AVALON_DB_DRIVER=subprocess" --env="AVALON_DBD_SECRET=" \
	--env="AVALON_PORT=$WORLD_PORT" --env="AVALON_MASTER_HOST=127.0.0.1" \
	--env="AVALON_MASTER_PORT=$MASTER_PORT" --env="AVALON_SPAWN_FIXED=1" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/server/world" --scene res://scenes/main.tscn \
	>"$WORLD_LOG" 2>&1 &
WORLD_PID=$!
for _ in $(seq 1 40); do
	grep -q "listening on enet://0.0.0.0:$WORLD_PORT" "$WORLD_LOG" 2>/dev/null && break
	sleep 1
done
grep -q "listening on enet://0.0.0.0:$WORLD_PORT" "$WORLD_LOG" || {
	log "FATAL: world never bound :$WORLD_PORT"
	tail -20 "$WORLD_LOG"
	exit 1
}
log "world up"

# ------------------------------------------------------------------ two piloted clients
launch_client() { # $1 token, $2 pilot dir
	"$GODOT" \
		--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=$WORLD_PORT" --env="AVALON_TOKEN=$1" \
		--env="AVALON_PILOT=1" --env="AVALON_PILOT_DIR=$2" \
		--env="AVALON_OBSERVE=1" --env="AVALON_OBSERVE_SECS=600" \
		--filesystem="$PROJECT_DIR" --filesystem=/tmp --filesystem="$OUT_DIR" \
		--headless --path "$PROJECT_DIR/client" --scene res://scenes/main.tscn \
		>"$2/client.log" 2>&1 &
}
log "launching piloted clients A ($USER_A) + B ($USER_B)"
launch_client "$TOKEN_A" "$DIR_A"
CLIENT_A_PID=$!
launch_client "$TOKEN_B" "$DIR_B"
CLIENT_B_PID=$!
for d in "$DIR_A" "$DIR_B"; do
	for _ in $(seq 1 60); do
		grep -q "\[pilot\] active" "$d/client.log" 2>/dev/null && break
		sleep 1
	done
	grep -q "\[pilot\] active" "$d/client.log" || {
		log "FATAL: pilot in $d never came up"
		tail -25 "$d/client.log"
		exit 1
	}
done
log "both pilots active"

pa() { AVALON_PILOT_DIR="$DIR_A" python3 "$SCRIPT_DIR/pilot.py" "$@"; }
pb() { AVALON_PILOT_DIR="$DIR_B" python3 "$SCRIPT_DIR/pilot.py" "$@"; }
pfield() { # pfield <a|b> <python-expr over d (the partystate dict)>
	local out
	if [ "$1" = a ]; then out=$(pa partystate 2>/dev/null); else out=$(pb partystate 2>/dev/null); fi
	echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin).get('party',{}); print($2)"
}
PHASE_RC=0
phase() { PHASE_RC=$RC; log "$1"; } # snapshot fails so the phase verdict below is honest
phase_verdict() { # phase_verdict <label>
	if [ "$RC" -eq "$PHASE_RC" ]; then log "$1 PASS"; else log "$1 FAILED (see FAIL lines above)"; fi
}
wait_for() { # wait_for <secs> <a|b> <expr> <expected> <desc>
	local i
	for i in $(seq 1 "$1"); do
		[ "$(pfield "$2" "$3")" = "$4" ] && return 0
		sleep 1
	done
	fail "$5 (last: '$(pfield "$2" "$3")')"
	return 1
}

# T-706/T-710: a fresh account auto-opens the Drillmaster's quest-offer panel — a visible
# full-rect Control that swallows GUI-stage mouse events, which would eat the rclick/look
# path below. Dismiss it on BOTH clients (it can land late; retry until the click finds no
# visible QoDecline). Harmless no-op once closed.
dismiss_offers() {
	local who ack
	for who in a b; do
		for _ in 1 2 3; do
			if [ "$who" = a ]; then ack=$(pa clicknode QoDecline 2>/dev/null); else ack=$(pb clicknode QoDecline 2>/dev/null); fi
			echo "$ack" | grep -q "no visible Control" && break
			sleep 1
		done
	done
}
pos_of() { # pos_of <a|b> -> "x z" of that client's own player (observe truth)
	local out
	if [ "$1" = a ]; then out=$(pa observe 2>/dev/null); else out=$(pb observe 2>/dev/null); fi
	echo "$out" | python3 -c "
import json, sys
p = json.load(sys.stdin).get('observe', {}).get('player', {}).get('position', {})
print(p.get('x'), p.get('z'))" 2>/dev/null
}
sleep 2
dismiss_offers
# Both spawn at the fixed origin. B sidesteps out of A's silhouette so A's ray can hit B.
pb hold D 1.2 >/dev/null
pa hold S 0.8 >/dev/null
sleep 3
log "positions after sidestep: A=($(pos_of a)) B=($(pos_of b))"

# ---- 1) A right-clicks B -> context menu -> Invite ------------------------------------------
phase "1) A right-clicks B's body and picks 'Invite to Party'"
# The rclick is a REAL screen-space click: B can sit at the view periphery or behind a spawn
# prop, so a miss is a legitimate real-client condition. Each miss aims A's camera at B's
# last unprojected screen position via the pilot `look` op (real RMB mouse-look; ~0.33 drag
# px per screen px at the default sensitivity/FOV) and retries; B keeps strafing so the
# geometry never wedges. Viewport center 576,324 = the headless client's 1152x648 default.
MENU_OPEN=false
for attempt in $(seq 1 8); do
	dismiss_offers # the offer can re-land mid-run; keep the GUI stage clear
	ACK=$(pa rclick "$USER_B" 2>/dev/null)
	sleep 1
	if grep -q "\[party\] context menu open for $USER_B" "$DIR_A/client.log"; then
		MENU_OPEN=true
		break
	fi
	read -r DX DY <<<"$(echo "$ACK" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if 'x' not in d:
        print(500, 0)  # target off/behind screen -> sweep the camera and re-try
    else:
        cx, cy = (v / 2.0 for v in d.get('vp', [1152, 648]))  # ack-reported viewport
        print(round((d['x'] - cx) * 0.33), round((d['y'] - cy) * 0.33))
except Exception:
    print(0, 0)")"
	log "   attempt $attempt missed — A=($(pos_of a)) B=($(pos_of b)) ack=$(echo "$ACK" | tr -d '\n ') aim: look $DX $DY"
	if [ "$DX" != "0" ] || [ "$DY" != "0" ]; then
		pa look "$DX" "$DY" >/dev/null
	fi
	pb hold D 0.5 >/dev/null
	sleep 2
done
$MENU_OPEN || fail "A's context menu never opened (8 aim attempts)"
pa clicknode CtxInviteParty >/dev/null
sleep 1
grep -q "\[party\] invite sent to $USER_B" "$DIR_A/client.log" ||
	fail "the menu click sent no invite"
wait_for 10 b "d.get('pending_from','')" "$USER_A" "B has no pending invite from A"
grep -q "\[party\] invite modal shown from $USER_A" "$DIR_B/client.log" ||
	fail "B's invite modal never showed"
phase_verdict "1/4 menu -> intent -> modal:"

# ---- 2) B accepts via the real button -> both rosters --------------------------------------
phase "2) B clicks Accept"
pb clicknode PartyInviteAccept >/dev/null
wait_for 10 a "','.join(sorted(d.get('members',[])))" "$USER_A,$USER_B" "A's roster != [A,B]"
wait_for 10 b "','.join(sorted(d.get('members',[])))" "$USER_A,$USER_B" "B's roster != [A,B]"
[ "$(pfield a "d.get('leader','')")" = "$USER_A" ] || fail "A is not the leader"
grep -q "\[party\] invite modal answered accept" "$DIR_B/client.log" ||
	fail "B's accept never went through the modal button"
# T-285 party frames: the roster that feeds them is live on both clients (asserted above); the
# frames Control itself renders rows on the next positions tick (visible only when 2+ rows).
pa ui 2>/dev/null | grep -q "PartyFrames" || fail "A's PartyFrames surface missing from the HUD"
phase_verdict "2/4 accept -> both rosters + frames feed:"

# ---- 3) three declines arm the cooldown; the 4th invite is refused, B stays silent ----------
phase "3) B leaves, then declines 3 invites; the 4th is server-refused"
pb party leave >/dev/null
wait_for 10 a "len(d.get('members',[]))" "0" "party did not clear after B left"
for i in 1 2 3; do
	pa party invite "$USER_B" >/dev/null
	wait_for 10 b "d.get('pending_from','')" "$USER_A" "decline round $i: no pending invite"
	pb clicknode PartyInviteDecline >/dev/null
	wait_for 10 b "d.get('pending_from','')" "" "decline round $i: pending never cleared"
done
MODALS_BEFORE=$(grep -c "invite modal shown" "$DIR_B/client.log")
pa party invite "$USER_B" >/dev/null
sleep 3
grep -q "\[party\] refused: invite_cooldown" "$DIR_A/client.log" ||
	fail "A never saw the invite_cooldown refusal"
MODALS_AFTER=$(grep -c "invite modal shown" "$DIR_B/client.log")
[ "$MODALS_BEFORE" = "$MODALS_AFTER" ] ||
	fail "B got a modal for a cooldown-blocked invite (should be silent)"
[ "$(pfield b "d.get('pending_from','')")" = "" ] ||
	fail "B has pending state from a blocked invite"
phase_verdict "3/4 cooldown blocks the 4th invite, decliner untouched:"

# ---- 4) the cooldown is per-pair: B -> A still works (modal accept path) --------------------
phase "4) B invites A (reverse direction, unthrottled)"
pb party invite "$USER_A" >/dev/null
wait_for 10 a "d.get('pending_from','')" "$USER_B" "A has no pending invite from B"
pa clicknode PartyInviteAccept >/dev/null
wait_for 10 a "','.join(sorted(d.get('members',[])))" "$USER_A,$USER_B" "reverse party A-side"
wait_for 10 b "','.join(sorted(d.get('members',[])))" "$USER_A,$USER_B" "reverse party B-side"
[ "$(pfield b "d.get('leader','')")" = "$USER_B" ] || fail "B is not the reverse-party leader"
phase_verdict "4/4 per-pair cooldown, reverse invite through the modal:"

pa quit >/dev/null 2>&1
pb quit >/dev/null 2>&1
if [[ $RC -ne 0 ]]; then
	log "--- A client log tail ---"
	tail -20 "$DIR_A/client.log"
	log "--- B client log tail ---"
	tail -20 "$DIR_B/client.log"
	log "--- world log tail ---"
	tail -10 "$WORLD_LOG"
fi
[[ $RC -eq 0 ]] && log "T736 INVITE E2E: PASS" || log "T736 INVITE E2E: FAIL"
exit $((RC > 0 ? 1 : 0))
