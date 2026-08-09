#!/usr/bin/env bash
# T-734 two-client E2E: the SERVER-authoritative day/night clock over real transport.
#
# ISOLATION (T-745 rule): NOTHING live is touched. Own Postgres container on :5435, own master
# on :9137 (AVALON_MASTER_PORT override), own world on :9237 — never 9001/9100/9200/5432, and no
# test rows in the live DB. Both piloted clients run THIS worktree's client code headlessly.
#
# WHAT IT PROVES, in order (the T-734 DoD):
#   1. Two clients in the same world report the SAME day_t within interpolation tolerance,
#      sampled repeatedly across a resync boundary — and the clock ADVANCES at the shared rate.
#   2. A client joining MID-CYCLE (B starts ~25 s after A) matches immediately via the
#      handshake_ok join snap — without sync its free-run would sit ~0.02 of a day away.
#   3. The clock CHECKPOINTS to the master's world.state KV (a real Postgres row appears).
#   4. The world clock SURVIVES a world-server restart: day_t resumes (>= the pre-kill value,
#      never reset to the 0.34 boot default), and a fresh client sees the resumed time.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
export AVALON_GODOT_PIN="${AVALON_GODOT_PIN:-native-4.7}"
GODOT="$SCRIPT_DIR/godot-bin.sh"

PG_TEST_PORT=5435 # never 5432 (live Postgres)
PG_CONTAINER=avalon-postgres-t734
MASTER_PORT=9137 # never 9100 (live master)
WORLD_PORT=9237  # never 9200 (live world)
OUT_DIR="${AVALON_TEST_LOG_DIR:-/tmp/avalon-tests-t734}"
DIR_A="$OUT_DIR/pilot-a"
DIR_B="$OUT_DIR/pilot-b"
DIR_A2="$OUT_DIR/pilot-a2"
MASTER_LOG="$OUT_DIR/t734-master.log"
WORLD_LOG="$OUT_DIR/t734-world.log"
WORLD_LOG2="$OUT_DIR/t734-world-restart.log"
USER_A=t734a
USER_B=t734b

export AVALON_PG_PASSWORD="t734_isolated_not_the_live_password"
export PG_HOST=127.0.0.1
export PG_PORT="$PG_TEST_PORT"
export PG_USER=avalon
JWT_SECRET="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # dummy, isolated stack only (t740 idiom)

log() { echo "[t734-e2e] $*"; }
RC=0
fail() {
	log "FAIL: $*"
	RC=$((RC + 1))
}
psql_row() { podman exec -i "$PG_CONTAINER" psql -U avalon -d avalon -tA -c "$1"; }
psql_exec() { podman exec -i "$PG_CONTAINER" psql -U avalon -d avalon -q -c "$1" >/dev/null; }

mkdir -p "$OUT_DIR"
rm -rf "$DIR_A" "$DIR_B" "$DIR_A2"
mkdir -p "$DIR_A" "$DIR_B" "$DIR_A2"

cleanup() {
	[[ -n "${CLIENT_A_PID:-}" ]] && kill "$CLIENT_A_PID" 2>/dev/null
	[[ -n "${CLIENT_B_PID:-}" ]] && kill "$CLIENT_B_PID" 2>/dev/null
	[[ -n "${CLIENT_A2_PID:-}" ]] && kill "$CLIENT_A2_PID" 2>/dev/null
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

# ------------------------------------------------------------------ isolated Postgres on :5435
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
log "applying init.sql + migrations (incl. 056 world.state)"
podman exec -i "$PG_CONTAINER" psql -U avalon -d avalon -q -v ON_ERROR_STOP=1 \
	<"$PROJECT_DIR/infra/postgres/init.sql" >/dev/null 2>&1 || {
	log "FATAL: init.sql failed"
	exit 1
}
bash "$SCRIPT_DIR/apply-migrations.sh" >"$OUT_DIR/t734-migrations.log" 2>&1 || {
	log "FATAL: migrations failed"
	tail -20 "$OUT_DIR/t734-migrations.log"
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

# ------------------------------------------------------------------ isolated master on :9137
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

# ------------------------------------------------------------------ isolated world on :9237
launch_world() { # $1 log file
	AVALON_PORT=$WORLD_PORT "$GODOT" \
		--env="AVALON_JWT_SECRET=$JWT_SECRET" \
		--env="AVALON_PG_PASSWORD=$AVALON_PG_PASSWORD" \
		--env="PG_HOST=127.0.0.1" --env="PG_PORT=$PG_TEST_PORT" --env="PG_USER=avalon" \
		--env="AVALON_DB_DRIVER=subprocess" --env="AVALON_DBD_SECRET=" \
		--env="AVALON_PORT=$WORLD_PORT" --env="AVALON_MASTER_HOST=127.0.0.1" \
		--env="AVALON_MASTER_PORT=$MASTER_PORT" --env="AVALON_SPAWN_FIXED=1" \
		--filesystem="$PROJECT_DIR" --filesystem=/tmp \
		--headless --path "$PROJECT_DIR/server/world" --scene res://scenes/main.tscn \
		>"$1" 2>&1 &
}
log "booting isolated world on enet://:$WORLD_PORT -> master :$MASTER_PORT"
launch_world "$WORLD_LOG"
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

# ------------------------------------------------------------------ piloted clients + helpers
launch_client() { # $1 token, $2 pilot dir
	"$GODOT" \
		--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=$WORLD_PORT" --env="AVALON_TOKEN=$1" \
		--env="AVALON_PILOT=1" --env="AVALON_PILOT_DIR=$2" \
		--env="AVALON_OBSERVE=1" --env="AVALON_OBSERVE_SECS=600" \
		--filesystem="$PROJECT_DIR" --filesystem=/tmp --filesystem="$OUT_DIR" \
		--headless --path "$PROJECT_DIR/client" --scene res://scenes/main.tscn \
		>"$2/client.log" 2>&1 &
}
wait_pilot() { # $1 pilot dir
	for _ in $(seq 1 60); do
		grep -q "\[pilot\] active" "$1/client.log" 2>/dev/null && break
		sleep 1
	done
	grep -q "\[pilot\] active" "$1/client.log" || {
		log "FATAL: pilot in $1 never came up"
		tail -25 "$1/client.log"
		exit 1
	}
}
day_of() { # day_of <pilot dir> -> that client's observed world.day_t (or -1)
	AVALON_PILOT_DIR="$1" python3 "$SCRIPT_DIR/pilot.py" observe 2>/dev/null | python3 -c "
import json, sys
print(json.load(sys.stdin).get('observe', {}).get('world', {}).get('day_t', -1))" 2>/dev/null
}
# wrapped |a-b| on the 0..1 day circle, compared against a tolerance -> OK/DRIFT
day_diff_ok() { # $1 a, $2 b, $3 tolerance
	python3 -c "
a, b, tol = float('$1'), float('$2'), float('$3')
d = abs(a - b) % 1.0
d = min(d, 1.0 - d)
print('OK' if d <= tol else 'DRIFT %.4f' % d)"
}
PHASE_RC=0
phase() {
	PHASE_RC=$RC
	log "$1"
}
phase_verdict() {
	if [ "$RC" -eq "$PHASE_RC" ]; then log "$1 PASS"; else log "$1 FAILED (see FAIL lines above)"; fi
}

# ---- 1) A joins; the shared clock advances at the day rate --------------------------------------
phase "1) client A joins; day_t is live and advancing at the shared rate"
launch_client "$TOKEN_A" "$DIR_A"
CLIENT_A_PID=$!
wait_pilot "$DIR_A"
grep -q "world_clock] no checkpoint; day_t=" "$WORLD_LOG" ||
	fail "fresh world did not log the no-checkpoint default"
DAY_A1=$(day_of "$DIR_A")
[ "$(python3 -c "print('yes' if 0.0 <= float('$DAY_A1') <= 1.0 else 'no')")" = yes ] ||
	fail "A's observed day_t is not a day fraction: '$DAY_A1'"
sleep 6
DAY_A2=$(day_of "$DIR_A")
# 6 real seconds = 0.005 of a 1200 s day; allow sampling slop but demand real advance.
python3 -c "
import sys
a1, a2 = float('$DAY_A1'), float('$DAY_A2')
adv = (a2 - a1) % 1.0
sys.exit(0 if 0.002 <= adv <= 0.012 else 1)" ||
	fail "A's clock did not advance at the day rate (a1=$DAY_A1 a2=$DAY_A2)"
phase_verdict "1/4 join + advancing clock:"

# ---- 2) B joins mid-cycle and matches immediately; both stay matched across a resync ------------
phase "2) B joins ~25 s into the cycle and matches A immediately"
sleep 12 # widen the gap an unsynced B free-run would show (~0.02 of a day by now)
launch_client "$TOKEN_B" "$DIR_B"
CLIENT_B_PID=$!
wait_pilot "$DIR_B"
DAY_B1=$(day_of "$DIR_B")
DAY_A3=$(day_of "$DIR_A")
VERDICT=$(day_diff_ok "$DAY_A3" "$DAY_B1" 0.005)
[ "$VERDICT" = OK ] || fail "mid-cycle join mismatch: A=$DAY_A3 B=$DAY_B1 ($VERDICT)"
# Sample twice more across the 15 s resync boundary — the DoD's interpolation tolerance.
for i in 1 2; do
	sleep 9
	DA=$(day_of "$DIR_A")
	DB=$(day_of "$DIR_B")
	VERDICT=$(day_diff_ok "$DA" "$DB" 0.005)
	[ "$VERDICT" = OK ] || fail "sample $i drifted: A=$DA B=$DB ($VERDICT)"
done
log "   A=$DA B=$DB (last sample)"
phase_verdict "2/4 mid-cycle join + interpolation tolerance:"

# ---- 3) the clock checkpoints to the master's world.state KV ------------------------------------
phase "3) world.state holds a fresh day_t checkpoint row"
ROW=$(psql_row "SELECT value FROM world.state WHERE key='day_t';")
[ -n "$ROW" ] || fail "no world.state day_t row after >5 s of uptime"
log "   checkpoint row: day_t=$ROW"
phase_verdict "3/4 Postgres checkpoint:"

# ---- 4) world restart resumes the clock (not a noon/default reset) ------------------------------
phase "4) world restart: day_t resumes where it left off"
DAY_BEFORE=$(day_of "$DIR_A")
kill "$CLIENT_A_PID" "$CLIENT_B_PID" 2>/dev/null
kill "$WORLD_PID" 2>/dev/null
sleep 2
pkill -f "AVALON_PORT=$WORLD_PORT" 2>/dev/null
sleep 1
launch_world "$WORLD_LOG2"
WORLD_PID=$!
for _ in $(seq 1 40); do
	grep -q "listening on enet://0.0.0.0:$WORLD_PORT" "$WORLD_LOG2" 2>/dev/null && break
	sleep 1
done
grep -q "listening on enet://0.0.0.0:$WORLD_PORT" "$WORLD_LOG2" ||
	fail "world never came back on :$WORLD_PORT"
for _ in $(seq 1 20); do
	grep -q "world_clock] resumed day_t=" "$WORLD_LOG2" 2>/dev/null && break
	sleep 1
done
grep -q "world_clock] resumed day_t=" "$WORLD_LOG2" ||
	fail "restarted world never logged a resumed checkpoint"
launch_client "$TOKEN_A" "$DIR_A2"
CLIENT_A2_PID=$!
wait_pilot "$DIR_A2"
DAY_AFTER=$(day_of "$DIR_A2")
# Resumed, not reset: >= (pre-kill - checkpoint staleness 5 s - slop), and clearly past the
# 0.34 boot default the pre-restart run has long left behind (~60+ s = 0.05 of a day).
python3 -c "
import sys
before, after = float('$DAY_BEFORE'), float('$DAY_AFTER')
lo = before - 0.006          # 5 s checkpoint staleness + slop
hi = before + 0.030          # restart window (~30 s) at the day rate + slop
ok = lo <= after <= hi and after > 0.355
sys.exit(0 if ok else 1)" ||
	fail "clock did not resume (before=$DAY_BEFORE after=$DAY_AFTER; reset-to-default?)"
log "   before=$DAY_BEFORE after=$DAY_AFTER (resumed)"
phase_verdict "4/4 restart persistence:"

AVALON_PILOT_DIR="$DIR_A2" python3 "$SCRIPT_DIR/pilot.py" quit >/dev/null 2>&1
if [[ $RC -ne 0 ]]; then
	log "--- A client log tail ---"
	tail -20 "$DIR_A/client.log"
	log "--- B client log tail ---"
	tail -20 "$DIR_B/client.log"
	log "--- world log tails ---"
	tail -10 "$WORLD_LOG"
	tail -10 "$WORLD_LOG2" 2>/dev/null
fi
[[ $RC -eq 0 ]] && log "T734 DAYCLOCK E2E: PASS" || log "T734 DAYCLOCK E2E: FAIL"
exit $((RC > 0 ? 1 : 0))
