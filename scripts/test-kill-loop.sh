#!/usr/bin/env bash
# test-kill-loop.sh — Prove one server-authoritative Strike kill loop over ENet.
#
# Starts/reuses the M0 server stack, seeds a real master session token, runs one
# headless client in ability-use mode against dummy mob 1001, and asserts only
# server-emitted combat results.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GODOT="org.godotengine.Godot"
WORLD_DIR="$PROJECT_DIR/server/world"
KILL_LOG="/tmp/avalon-kill-loop-client.log"
RANGE_LOG="/tmp/avalon-kill-loop-range-client.log"
KILL_RESULT="/tmp/avalon-kill-loop-result.json"
RANGE_RESULT="/tmp/avalon-kill-loop-range-result.json"
TOKENS_ENV="/tmp/avalon-kill-loop-tokens.env"

log() { echo "[test-kill-loop] $*"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then
	set -a
	# shellcheck disable=SC1091
	source "$PROJECT_DIR/.env"
	set +a
fi
if [[ -z "${AVALON_JWT_SECRET:-}" ]]; then
	log "FATAL: AVALON_JWT_SECRET not set (.env missing?)"
	exit 1
fi
export AVALON_JWT_SECRET
export AVALON_JWT_REFRESH_SECRET="${AVALON_JWT_REFRESH_SECRET:-}"
export AVALON_PG_PASSWORD="${AVALON_PG_PASSWORD:-}"

_started_servers=false
servers_up() {
	ss -ulnp 2>/dev/null | grep -q ":9200" && ss -tlnp 2>/dev/null | grep -q ":9100"
}
cleanup() {
	if [[ "$_started_servers" == "true" ]]; then
		log "Stopping servers..."
		bash scripts/dev-down.sh >/dev/null 2>&1
	fi
}
trap cleanup EXIT

if servers_up; then
	log "Using existing servers"
else
	log "Starting servers..."
	bash scripts/dev-up.sh >/dev/null 2>&1
	_started_servers=true
	sleep 4
fi
if ! servers_up; then
	log "FATAL: servers not ready on 9100/9200"
	exit 1
fi

python3 - << 'PYEOF'
import base64, hashlib, hmac, json, os, subprocess, time

secret = os.environ["AVALON_JWT_SECRET"]

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

def make_jwt(sub):
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({
        "sub": sub,
        "iat": int(time.time()),
        "exp": int(time.time()) + 3600,
        "iss": "avalon",
    }, separators=(",", ":")).encode())
    sig = hmac.new(secret.encode(), (header + "." + payload).encode(), hashlib.sha256).hexdigest()
    return header + "." + payload + "." + sig

tokens = {}
for username in ("kill_loop_range", "kill_loop_kill", "kill_loop_stale_a", "kill_loop_stale_b"):
    token = make_jwt(username)
    tokens[username] = token
    sql = (
        "INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked) "
        "VALUES ('" + token + "', '" + username + "', NOW(), NOW() + INTERVAL '1 hour', false) "
        "ON CONFLICT (token) DO UPDATE SET username = '" + username + "', revoked = false;"
    )
    subprocess.run(
        ["bash", "-c", "podman exec avalon-postgres psql -U avalon -d avalon -c \"" + sql + "\""],
        check=True,
        capture_output=True,
    )
with open("/tmp/avalon-kill-loop-tokens.env", "w", encoding="utf-8") as fh:
    fh.write("TOKEN_RANGE=" + tokens["kill_loop_range"] + "\n")
    fh.write("TOKEN_KILL=" + tokens["kill_loop_kill"] + "\n")
    fh.write("TOKEN_STALE_A=" + tokens["kill_loop_stale_a"] + "\n")
    fh.write("TOKEN_STALE_B=" + tokens["kill_loop_stale_b"] + "\n")
PYEOF
if [[ ! -f "$TOKENS_ENV" ]]; then
	log "FATAL: token seed failed"
	exit 1
fi
source "$TOKENS_ENV"

run_ability_client() {
	local token="$1"
	local result_file="$2"
	local log_file="$3"
	local move_to_target="$4"
	local repeat="$5"
	local gap_ms="$6"
	local linger_ms="${7:-0}"

	rm -f "$result_file" "$log_file"
	timeout 200 flatpak run \
		--env="AVALON_ABILITY_LINGER_MS=$linger_ms" \
		--env="AVALON_HOST=127.0.0.1" \
		--env="AVALON_PORT=9200" \
		--env="AVALON_TOKEN=$token" \
		--env="AVALON_RESULT_FILE=$result_file" \
		--env="AVALON_USE_ABILITY=1" \
		--env="AVALON_ABILITY_ID=1" \
		--env="AVALON_ABILITY_TARGET=1001" \
		--env="AVALON_ABILITY_REPEAT=$repeat" \
		--env="AVALON_ABILITY_GAP_MS=$gap_ms" \
		--env="AVALON_ABILITY_MOVE_TO_TARGET=$move_to_target" \
		--filesystem="$PROJECT_DIR" \
		--filesystem=/tmp \
		"$GODOT" --headless --path "$WORLD_DIR" \
		--scene res://tests/test_client.tscn > "$log_file" 2>&1
}

log "Running out-of-range rejection check against mob 1001..."
run_ability_client "$TOKEN_RANGE" "$RANGE_RESULT" "$RANGE_LOG" 0 1 1600
range_exit=$?
sleep 1

log "Running in-range kill loop against mob 1001 (+15s regen linger, T-071)..."
run_ability_client "$TOKEN_KILL" "$KILL_RESULT" "$KILL_LOG" 1 20 1600 15000
kill_exit=$?

# ---- Phase 3 (T-070): stale kill credit across respawn ----
# A kills the dummy and STAYS CONNECTED (its threat entry survives disconnect-cleanup);
# after the respawn B kills it alone. B's mob_death must credit ONLY B — before T-070
# the mob's threat table survived death, so A was credited with a kill it never touched.
STALE_A_RESULT="/tmp/avalon-kill-loop-stale-a.json"
STALE_B_RESULT="/tmp/avalon-kill-loop-stale-b.json"
log "Phase 3: waiting out the phase-2 respawn (32s)..."
sleep 32
log "Phase 3: client A kills, lingers 80s connected..."
run_ability_client "$TOKEN_STALE_A" "$STALE_A_RESULT" "/tmp/avalon-kill-loop-stale-a.log" 1 20 1600 80000 &
stale_a_pid=$!
sleep 25
log "Phase 3: client B kill loop across the respawn..."
run_ability_client "$TOKEN_STALE_B" "$STALE_B_RESULT" "/tmp/avalon-kill-loop-stale-b.log" 1 30 2000
stale_b_exit=$?
wait "$stale_a_pid"
stale_a_exit=$?

python3 - "$KILL_RESULT" "$RANGE_RESULT" "$kill_exit" "$range_exit" << 'PYEOF'
import json, sys

kill_path, range_path, kill_exit, range_exit = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

errors = []
try:
    kill = load(kill_path)
except Exception as exc:
    print(f"[test-kill-loop] FAIL — could not read kill result: {exc}")
    sys.exit(1)
try:
    range_result = load(range_path)
except Exception as exc:
    print(f"[test-kill-loop] FAIL — could not read range result: {exc}")
    sys.exit(1)

if kill_exit != 0:
    errors.append(f"kill client exit={kill_exit}")
if range_exit != 0:
    errors.append(f"range client exit={range_exit}")
if kill.get("handshake_ok") is not True:
    errors.append("kill handshake_ok != true")
if kill.get("mob_killed") is not True:
    errors.append("mob_killed != true")
if kill.get("damage_attributed_by_server") is not True:
    errors.append("damage_attributed_by_server != true")
if kill.get("mob_death_count") != 1:
    errors.append(f"mob_death_count={kill.get('mob_death_count')}")

kill_results = [
    r for r in kill.get("results_received", [])
    if r.get("type") == "ability_result" and r.get("target_id") == 1001
]
if not kill_results:
    errors.append("no ability_result for target 1001")
if len(kill_results) > kill.get("intents_sent", 0):
    errors.append("more ability_result rows than intents sent")

hps = [int(r.get("target_hp", -1)) for r in kill_results]
if any(hp < 0 for hp in hps):
    errors.append(f"invalid target_hp sequence={hps}")
if any(hps[i] > hps[i - 1] for i in range(1, len(hps))):
    errors.append(f"target_hp not monotonic non-increasing: {hps}")
if hps and hps[-1] != 0:
    errors.append(f"final target_hp={hps[-1]}")

if range_result.get("handshake_ok") is not True:
    errors.append("range handshake_ok != true")
range_rejections = range_result.get("rejections_received", [])
if not any(r.get("reason") == "out_of_range" for r in range_rejections):
    errors.append(f"missing out_of_range rejection: {range_rejections}")
range_damage = [
    r for r in range_result.get("results_received", [])
    if r.get("type") == "ability_result" and r.get("target_id") == 1001
]
if range_damage:
    errors.append(f"out-of-range produced damage: {range_damage}")
if range_result.get("mob_death_count", 0) != 0:
    errors.append(f"out-of-range mob_death_count={range_result.get('mob_death_count')}")

# T-071: the kill client tanks the dummy (T-070 aggro) then lingers 15s — HP must have
# recovered out of combat (regen wired into the live tick).
hp_min, hp_last = int(kill.get("my_hp_min", -1)), int(kill.get("my_hp_last", -1))
if hp_min < 0 or hp_last < 0:
    errors.append("no own-HP samples recorded (positions broadcast missing hp?)")
elif hp_last <= hp_min:
    errors.append(
        f"no HP recovery after combat (min={hp_min}, last={hp_last}) — T-071 regen not wired"
    )

if errors:
    print("[test-kill-loop] FAIL — " + "; ".join(errors))
    print("[test-kill-loop] kill_result=" + json.dumps(kill, separators=(",", ":")))
    print("[test-kill-loop] range_result=" + json.dumps(range_result, separators=(",", ":")))
    sys.exit(1)

print(
    "[test-kill-loop] PASS — handshake=true, intents=%d, ability_results=%d, mob_death=1, out_of_range=true, hp_recovered=%d->%d"
    % (kill.get("intents_sent", 0), len(kill_results), hp_min, hp_last)
)
PYEOF
phase12_exit=$?

python3 - "$STALE_A_RESULT" "$STALE_B_RESULT" "$stale_a_exit" "$stale_b_exit" << 'PYEOF'
import json, sys

a_path, b_path, a_exit, b_exit = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

errors = []
try:
    a = load(a_path)
    b = load(b_path)
except Exception as exc:
    print(f"[test-kill-loop] FAIL (phase 3) — could not read results: {exc}")
    sys.exit(1)

if a_exit != 0:
    errors.append(f"stale client A exit={a_exit}")
if b_exit != 0:
    errors.append(f"stale client B exit={b_exit}")
if a.get("mob_killed") is not True:
    errors.append("client A never killed the dummy (phase timing broke)")
if b.get("mob_killed") is not True:
    errors.append("client B never killed the respawned dummy (phase timing broke)")
b_credit = b.get("mob_death_credited", [])
b_peer = b.get("peer_id", -1)
a_peer = a.get("peer_id", -2)
if a_peer in b_credit:
    errors.append(
        f"T-070 REGRESSION: A (peer {a_peer}) credited for B's kill across the respawn"
        f" (credited={b_credit})"
    )
if b_peer not in b_credit:
    errors.append(f"B (peer {b_peer}) missing from its own kill credit (credited={b_credit})")

if errors:
    print("[test-kill-loop] FAIL (phase 3) — " + "; ".join(errors))
    print("[test-kill-loop] a_result=" + json.dumps(a, separators=(",", ":")))
    print("[test-kill-loop] b_result=" + json.dumps(b, separators=(",", ":")))
    sys.exit(1)

print(
    "[test-kill-loop] PASS (phase 3) — respawned-mob kill credited ONLY B (credited=%s)"
    % b_credit
)
PYEOF
phase3_exit=$?
exit $(( phase12_exit || phase3_exit ))
