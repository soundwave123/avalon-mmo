#!/usr/bin/env bash
# T-740 E2E — a provisioned one-time password must force a real password choice, over real
# transport, and then be dead forever.
#
# Unit tests can prove Auth.set_password's decision table. Only a real WebSocket against a real
# gateway backed by a real Postgres can prove the thing the owner actually asked for: that a
# friend types the 12 characters we read down the phone, picks their own password ONCE, and is in
# the world in a single round trip — with the old string worthless the moment they do.
#
# ISOLATION (T-745): this NEVER touches the live stack. It stands up its OWN Postgres container on
# :5433 and its OWN gateway on :9241 — never 9001/9100/9200, never the live `avalon` DB, and it
# creates no characters. The DB name is hardcoded `avalon` in both DB drivers, so isolating by
# database name is impossible; a second Postgres instance is the only honest isolation available.
# AVALON_DBD_SECRET is deliberately blanked so the sidecar path cannot reach the live daemon.
#
# WHAT IT PROVES, in order (order matters — the rate-limit phase poisons the bucket for 60 s, so
# every success path runs first):
#   1. provision  → tester-accounts.sh prints a 12-char readable OTP and flags the row
#   2. OTP login  → password_change_required, NOT a session
#   3. set_password on the SAME socket → login_ok with both tokens (one round trip)
#   4. the flag is cleared in the database
#   5. relog with the personal password → login_ok
#   6. a normal (non-OTP) account is untouched by all of this
#   7. the OTP is rejected afterwards, both as a login and as a replayed set_password
#   8. set_password spends the SAME rate-limit budget as login
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
export AVALON_GODOT_PIN="${AVALON_GODOT_PIN:-native-4.7}"
GODOT="$SCRIPT_DIR/godot-bin.sh"

GATEWAY_PORT=9241          # never 9001 (live gateway)
WORLD_ANNOUNCE_PORT=9242   # never 9200 (live world); only echoed in login_ok
PG_TEST_PORT=5433          # never 5432 (live Postgres)
PG_CONTAINER=avalon-postgres-t740
OUT_DIR="${AVALON_TEST_LOG_DIR:-/tmp/avalon-tests-t740}"
WORK_DIR="$OUT_DIR/t740-work"
GATEWAY_LOG="$OUT_DIR/t740-gateway.log"
DRIVER_LOG="$OUT_DIR/t740-driver.log"

OTP_USER=t740_first
NORMAL_USER=t740_settled
CHOSEN_PASSWORD="my own password"

export AVALON_PG_PASSWORD="t740_isolated_not_the_live_password"
export PG_HOST=127.0.0.1
export PG_PORT="$PG_TEST_PORT"
export PG_USER=avalon

log() { echo "[t740-e2e] $*"; }

mkdir -p "$OUT_DIR" "$WORK_DIR/infra/feedback"

cleanup() {
	[[ -n "${GATEWAY_PID:-}" ]] && kill "$GATEWAY_PID" 2>/dev/null
	pkill -f "AVALON_GATEWAY_PORT=$GATEWAY_PORT" 2>/dev/null
	podman rm -f "$PG_CONTAINER" >/dev/null 2>&1
	return 0
}
trap cleanup EXIT

for tool in podman psql python3; do
	command -v "$tool" >/dev/null 2>&1 || { log "FATAL: $tool is required"; exit 2; }
done
python3 -c "import websockets" 2>/dev/null || { log "FATAL: python websockets missing"; exit 2; }

# ------------------------------------------------------------------ isolated Postgres on :5433
log "starting isolated Postgres ($PG_CONTAINER) on :$PG_TEST_PORT"
podman rm -f "$PG_CONTAINER" >/dev/null 2>&1
podman run -d --name "$PG_CONTAINER" \
	-p "127.0.0.1:$PG_TEST_PORT:5432" \
	-e POSTGRES_USER=avalon -e POSTGRES_PASSWORD="$AVALON_PG_PASSWORD" -e POSTGRES_DB=avalon \
	docker.io/library/postgres:17-alpine >/dev/null || { log "FATAL: podman run failed"; exit 1; }

for _ in $(seq 1 60); do
	podman exec "$PG_CONTAINER" pg_isready -U avalon -d avalon >/dev/null 2>&1 && break
	sleep 1
done
podman exec "$PG_CONTAINER" pg_isready -U avalon -d avalon >/dev/null 2>&1 || {
	log "FATAL: isolated Postgres never became ready"; podman logs "$PG_CONTAINER" | tail -20; exit 1; }
log "isolated Postgres ready"

log "applying init.sql + every migration (including 055_add_password_otp)"
podman exec -i "$PG_CONTAINER" psql -U avalon -d avalon -q -v ON_ERROR_STOP=1 \
	< "$PROJECT_DIR/infra/postgres/init.sql" >/dev/null 2>&1 \
	|| { log "FATAL: init.sql failed"; exit 1; }
bash "$SCRIPT_DIR/apply-migrations.sh" > "$OUT_DIR/t740-migrations.log" 2>&1 \
	|| { log "FATAL: migrations failed"; tail -20 "$OUT_DIR/t740-migrations.log"; exit 1; }
grep -q "applying 055_add_password_otp.sql" "$OUT_DIR/t740-migrations.log" \
	|| { log "FATAL: migration 055 never ran — the rest of this test would be meaningless"; exit 1; }
log "$(grep '^\[apply-migrations\] done:' "$OUT_DIR/t740-migrations.log")"

RC=0
fail() { log "FAIL: $*"; RC=1; }

sql_scalar() {
	PGPASSWORD="$AVALON_PG_PASSWORD" psql -h 127.0.0.1 -p "$PG_TEST_PORT" -U avalon -d avalon \
		-tA -c "$1" 2>/dev/null | tr -d '[:space:]'
}

# --------------------------------------------------------------------------------- provisioning
# Run from WORK_DIR: tester-accounts.sh syncs the portal dropdown to a CWD-relative path, and the
# repo's real infra/feedback/testers.txt must not learn about throwaway test accounts.
log "provisioning $OTP_USER via scripts/tester-accounts.sh add"
ADD_OUT="$(cd "$WORK_DIR" && bash "$SCRIPT_DIR/tester-accounts.sh" add "$OTP_USER" 2>&1)"
echo "$ADD_OUT" > "$OUT_DIR/t740-provision.log"
OTP="$(grep '^password:' <<<"$ADD_OUT" | head -1 | sed 's/^password: *//')"

[[ ${#OTP} -eq 12 ]] || fail "the printed password is ${#OTP} chars, expected 12"
grep -qE "^[23456789ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz]{12}$" <<<"$OTP" \
	|| fail "the OTP contains a character outside the readable alphabet: $OTP"
grep -q "one-time — they'll pick their own" <<<"$ADD_OUT" \
	|| fail "the provisioning output never says the password is one-time"
[[ "$(sql_scalar "SELECT password_is_otp FROM auth.accounts WHERE username='$OTP_USER'")" == "t" ]] \
	|| fail "the provisioned row is not flagged password_is_otp"
log "provisioned $OTP_USER with a 12-char readable OTP, row flagged"

# A settled account: provisioned the same way, then its flag cleared exactly as a first login
# would — this is the "every existing account keeps working unchanged" control.
NORMAL_OUT="$(cd "$WORK_DIR" && bash "$SCRIPT_DIR/tester-accounts.sh" add "$NORMAL_USER" 2>&1)"
NORMAL_PW="$(grep '^password:' <<<"$NORMAL_OUT" | head -1 | sed 's/^password: *//')"
sql_scalar "UPDATE auth.accounts SET password_is_otp=false WHERE username='$NORMAL_USER'" >/dev/null

# ------------------------------------------------------------------- isolated gateway on :9241
log "booting isolated gateway on ws://127.0.0.1:$GATEWAY_PORT"
"$GODOT" --headless --path "$PROJECT_DIR/server/gateway" --import >/dev/null 2>&1
AVALON_GATEWAY_PORT=$GATEWAY_PORT "$GODOT" \
	--env="AVALON_GATEWAY_PORT=$GATEWAY_PORT" \
	--env="AVALON_PORT=$WORLD_ANNOUNCE_PORT" \
	--env="AVALON_AUTH_MODE=accounts" \
	--env="AVALON_JWT_SECRET=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
	--env="AVALON_JWT_REFRESH_SECRET=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
	--env="AVALON_PG_PASSWORD=$AVALON_PG_PASSWORD" \
	--env="PG_HOST=127.0.0.1" --env="PG_PORT=$PG_TEST_PORT" --env="PG_USER=avalon" \
	--env="AVALON_DB_DRIVER=subprocess" --env="AVALON_DBD_SECRET=" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	--headless --path "$PROJECT_DIR/server/gateway" --scene res://scenes/main.tscn \
	>"$GATEWAY_LOG" 2>&1 &
GATEWAY_PID=$!
for _ in $(seq 1 60); do
	grep -q "listening on ws://0.0.0.0:$GATEWAY_PORT" "$GATEWAY_LOG" 2>/dev/null && break
	sleep 0.5
done
grep -q "listening on ws://0.0.0.0:$GATEWAY_PORT" "$GATEWAY_LOG" || {
	log "FATAL: gateway never bound :$GATEWAY_PORT (live-port fallback would be a test hazard)"
	tail -20 "$GATEWAY_LOG"; exit 1; }
log "gateway up"

# ------------------------------------------------------------------------------- the real flow
python3 "$SCRIPT_DIR/t740_otp_driver.py" \
	"ws://127.0.0.1:$GATEWAY_PORT" \
	"$OTP_USER" "$OTP" "$CHOSEN_PASSWORD" "$NORMAL_USER" "$NORMAL_PW" 2>&1 | tee "$DRIVER_LOG"
DRIVER_RC="${PIPESTATUS[0]}"
[[ "$DRIVER_RC" -eq 0 ]] || fail "the WebSocket flow failed (see $DRIVER_LOG)"

# --------------------------------------------------------------------- database-side assertions
[[ "$(sql_scalar "SELECT password_is_otp FROM auth.accounts WHERE username='$OTP_USER'")" == "f" ]] \
	|| fail "password_is_otp was not cleared by set_password"
STORED="$(sql_scalar "SELECT password_hash FROM auth.accounts WHERE username='$OTP_USER'")"
grep -qE "^sha256\\\$[0-9a-f]{32}\\\$[0-9a-f]{64}$" <<<"$STORED" \
	|| fail "the stored password is not a sha256\$salt\$digest record: $STORED"
grep -q "password set for $OTP_USER (one-time password consumed)" "$GATEWAY_LOG" \
	|| fail "the gateway never logged the password change"

if [[ $RC -ne 0 ]]; then
	log "--- gateway log ---"; grep "\[gateway\]" "$GATEWAY_LOG" | tail -25
fi
[[ $RC -eq 0 ]] && log "PASS" || log "FAIL (rc=$RC)"
exit $RC
