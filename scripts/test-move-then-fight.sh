#!/usr/bin/env bash
# test-move-then-fight.sh — T-067: server logic must read LIVE player positions.
#
# Two probes against the real stack over ENet:
#   A (aggro):  client moves onto the dummy (10,10) and lingers — the mob must
#               aggro the LIVE position and land at least one melee hit on it.
#   B (cast):   client moves to (10,10), stands still, casts Emberstrike (40-tick
#               cast) — the cast must NOT die to a spurious "moved" cancel
#               (the login-frozen-position signature). Mob-target completion is
#               asserted by T-068's harness, not here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GODOT="org.godotengine.Godot"
WORLD_DIR="$PROJECT_DIR/server/world"
AGGRO_LOG="/tmp/avalon-move-fight-aggro.log"
CAST_LOG="/tmp/avalon-move-fight-cast.log"
AGGRO_RESULT="/tmp/avalon-move-fight-aggro-result.json"
CAST_RESULT="/tmp/avalon-move-fight-cast-result.json"
TOKENS_ENV="/tmp/avalon-move-fight-tokens.env"

log() { echo "[test-move-then-fight] $*"; }

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
for username in ("move_fight_aggro", "move_fight_cast"):
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
with open("/tmp/avalon-move-fight-tokens.env", "w", encoding="utf-8") as fh:
    fh.write("TOKEN_AGGRO=" + tokens["move_fight_aggro"] + "\n")
    fh.write("TOKEN_CAST=" + tokens["move_fight_cast"] + "\n")
PYEOF
if [[ ! -f "$TOKENS_ENV" ]]; then
	log "FATAL: token seed failed"
	exit 1
fi
source "$TOKENS_ENV"

run_client() {
	local token="$1" result_file="$2" log_file="$3"
	local ability_id="$4" repeat="$5" gap_ms="$6" aggro_wait_ms="$7"

	rm -f "$result_file" "$log_file"
	timeout 120 flatpak run \
		--env="AVALON_HOST=127.0.0.1" \
		--env="AVALON_PORT=9200" \
		--env="AVALON_TOKEN=$token" \
		--env="AVALON_RESULT_FILE=$result_file" \
		--env="AVALON_USE_ABILITY=1" \
		--env="AVALON_ABILITY_ID=$ability_id" \
		--env="AVALON_ABILITY_TARGET=1001" \
		--env="AVALON_ABILITY_REPEAT=$repeat" \
		--env="AVALON_ABILITY_GAP_MS=$gap_ms" \
		--env="AVALON_ABILITY_MOVE_TO_TARGET=1" \
		--env="AVALON_ABILITY_AGGRO_WAIT_MS=$aggro_wait_ms" \
		--filesystem="$PROJECT_DIR" \
		--filesystem=/tmp \
		"$GODOT" --headless --path "$WORLD_DIR" \
		--scene res://tests/test_client.tscn > "$log_file" 2>&1
}

log "Probe A: move onto dummy (10,10), linger 12s — mob must aggro the LIVE position..."
run_client "$TOKEN_AGGRO" "$AGGRO_RESULT" "$AGGRO_LOG" 1 0 1600 12000
aggro_exit=$?
sleep 1

log "Probe B: move to (10,10), stand still, cast Emberstrike x2 — no 'moved' cancel..."
run_client "$TOKEN_CAST" "$CAST_RESULT" "$CAST_LOG" 2 2 8000 0
cast_exit=$?

python3 - "$AGGRO_RESULT" "$CAST_RESULT" "$aggro_exit" "$cast_exit" << 'PYEOF'
import json, sys

aggro_path, cast_path, aggro_exit, cast_exit = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
)

def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

errors = []
try:
    aggro = load(aggro_path)
except Exception as exc:
    print(f"[test-move-then-fight] FAIL — could not read aggro result: {exc}")
    sys.exit(1)
try:
    cast = load(cast_path)
except Exception as exc:
    print(f"[test-move-then-fight] FAIL — could not read cast result: {exc}")
    sys.exit(1)

if aggro_exit != 0:
    errors.append(f"aggro client exit={aggro_exit}")
if cast_exit != 0:
    errors.append(f"cast client exit={cast_exit}")

# Probe A: the mob must have hit ME at my post-move position.
if aggro.get("handshake_ok") is not True:
    errors.append("aggro handshake_ok != true")
if int(aggro.get("attacks_on_me", 0)) < 1:
    errors.append(
        f"mob never attacked the moved player (attacks_on_me={aggro.get('attacks_on_me')})"
        " — server AI is reading a stale position"
    )

# Probe B: a stationary post-move cast must not be cancelled with reason "moved".
if cast.get("handshake_ok") is not True:
    errors.append("cast handshake_ok != true")
if int(cast.get("cast_started_count", 0)) < 1:
    errors.append(f"no cast_started (count={cast.get('cast_started_count')})")
reasons = cast.get("cast_cancel_reasons", [])
if "moved" in reasons:
    errors.append(
        f"stationary cast cancelled with 'moved' (reasons={reasons})"
        " — per-tick cast check is reading a stale position"
    )

if errors:
    print("[test-move-then-fight] FAIL — " + "; ".join(errors))
    print("[test-move-then-fight] aggro_result=" + json.dumps(aggro, separators=(",", ":")))
    print("[test-move-then-fight] cast_result=" + json.dumps(cast, separators=(",", ":")))
    sys.exit(1)

print(
    "[test-move-then-fight] PASS — attacks_on_me=%d, cast_started=%d, cancel_reasons=%s"
    % (int(aggro.get("attacks_on_me", 0)), int(cast.get("cast_started_count", 0)), reasons)
)
PYEOF
