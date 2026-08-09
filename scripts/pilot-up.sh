#!/usr/bin/env bash
# pilot-up.sh — T-075: launch the client under agent control (Pilot enabled).
#
# Like play.sh, but: AVALON_PILOT=1 (command-file automation), explicit flatpak --env/--filesystem
# (the sandbox must see /tmp for screenshots + the command protocol), fresh pilot dir, and the
# client runs in the BACKGROUND (drive it with scripts/pilot.py; stop with pilot.py quit).
#
# T-339: AVALON_XVFB=1 runs the client under `xvfb-run` (virtual framebuffer) instead of the real
# display — the community gdUnit4-CI approach. Motivation: some hosts throttle an unfocused
# window's render loop (screenshot bursts cost seconds/frame); a client that owns its own virtual
# display is always "focused" and renders full-rate regardless of what has real input focus.
# Requires `xvfb-run` (or a bare `Xvfb` + manual DISPLAY) on the host — this script does NOT
# install it; if neither is present it FAILS FAST with a clear message (documented blocker).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# GPU graphics guard (595.84 Blackwell Xid-79 wait-mode) — refuse to render locally while locked.
bash "$PROJECT_DIR/scripts/ops/gpu-graphics-guard.sh" || exit 1

CLIENT_DIR="$PROJECT_DIR/client"
USER_NAME="${1:-pilot}"
PILOT_DIR="${AVALON_PILOT_DIR:-/tmp/avalon-pilot}"
XVFB="${AVALON_XVFB:-0}"
# T-346: THE single pinned capture resolution — feeds BOTH the boot --resolution CLI flag and the
# AVALON_PILOT_RESOLUTION env main.gd re-applies once it's booted (T-347 found this machine's
# persisted user://settings.cfg can carry window_mode=1/fullscreen from an old manual play
# session, silently resizing the window to the host's native display and blowing up qa-tour/
# visual-regress goldens host-to-host). One variable, one value, everywhere.
RESOLUTION="${AVALON_PILOT_RESOLUTION:-1280x720}"
log() { echo "[pilot-up] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1"; }

if [[ "$XVFB" == "1" ]]; then
	if command -v xvfb-run >/dev/null 2>&1; then
		log "AVALON_XVFB=1: launching under xvfb-run."
	elif command -v Xvfb >/dev/null 2>&1; then
		log "AVALON_XVFB=1: xvfb-run missing but Xvfb is present — launching a manual virtual display."
	else
		log "FATAL: AVALON_XVFB=1 requested but neither xvfb-run nor Xvfb is installed on this host."
		log "Not installing anything (standing orders) — this is a documented blocker. Unset AVALON_XVFB to use the real display."
		exit 3
	fi
fi

if [[ -f "$PROJECT_DIR/.env" ]]; then set -a; source "$PROJECT_DIR/.env"; set +a; fi
[[ -n "${AVALON_JWT_SECRET:-}" ]] || { log "FATAL: AVALON_JWT_SECRET not set"; exit 1; }
export AVALON_JWT_SECRET AVALON_JWT_REFRESH_SECRET="${AVALON_JWT_REFRESH_SECRET:-}" \
	AVALON_PG_PASSWORD="${AVALON_PG_PASSWORD:-}"

servers_up() { ss -ulnp 2>/dev/null | grep -q ":9200" && ss -tlnp 2>/dev/null | grep -q ":9100"; }
if ! servers_up; then
	log "Starting servers (dev-up)..."
	bash scripts/dev-up.sh >/dev/null 2>&1
	sleep 4
fi
servers_up || { log "FATAL: servers not ready"; exit 1; }

TOKEN="$(python3 - << PYEOF
import base64, hashlib, hmac, json, os, time
secret = os.environ["AVALON_JWT_SECRET"]
def b64url(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
header = b64url(json.dumps({"alg":"HS256","typ":"JWT"},separators=(",",":")).encode())
payload = b64url(json.dumps({"sub":"$USER_NAME","iat":int(time.time()),
    "exp":int(time.time())+7200,"iss":"avalon"},separators=(",",":")).encode())
sig = hmac.new(secret.encode(), (header+"."+payload).encode(), hashlib.sha256).hexdigest()
print(header+"."+payload+"."+sig)
PYEOF
)"
[[ -n "$TOKEN" ]] || { log "FATAL: token gen failed"; exit 1; }

log "Seeding session + character for '$USER_NAME'..."
psql_exec "INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked)
	VALUES ('$TOKEN', '$USER_NAME', NOW(), NOW() + INTERVAL '2 hours', false)
	ON CONFLICT (token) DO UPDATE SET username='$USER_NAME', revoked=false;" >/dev/null
# T-566: T-507's multi-character migration (044_add_multi_character.sql) dropped the plain
# UNIQUE(username) constraint chars.characters used to have — uniqueness now lives on partial
# indexes over LIVE rows only: (name) and (username, slot). `ON CONFLICT (username)` no longer
# matches ANY constraint/index, so Postgres rejected the statement outright every boot (a noisy
# but non-blocking error — the server lazily creates the row on first login anyway, see
# character_manager.gd). Mirror the same idempotent-seed idiom the server itself uses
# (character_manager.gd's create_character(), character_roster.gd): a NOT EXISTS guard against
# live rows + a bare ON CONFLICT DO NOTHING (valid without a conflict target — matches any unique
# violation instead of requiring index inference).
# T-716: name_chosen=false mirrors the master's bootstrap insert — this seeded character is named
# after the ACCOUNT, so it still owes the in-world name step. Omitting it takes the column DEFAULT
# (true, correct for real alts) and the harness would silently never see the name modal.
psql_exec "INSERT INTO chars.characters (username, name, slot, name_chosen)
	SELECT '$USER_NAME', '$USER_NAME', 0, false WHERE NOT EXISTS (
		SELECT 1 FROM chars.characters
		WHERE (username = '$USER_NAME' OR name = '$USER_NAME') AND deleted_at IS NULL
	)
	ON CONFLICT DO NOTHING;" >/dev/null

# One piloted client at a time — survivors race the shared command file (acks collide).
if [[ -f "$PILOT_DIR/client.pid" ]]; then
	kill "$(cat "$PILOT_DIR/client.pid")" 2>/dev/null && sleep 1
fi
rm -rf "$PILOT_DIR"
mkdir -p "$PILOT_DIR"

log "Launching PILOTED client as '$USER_NAME' (log: $PILOT_DIR/client.log)"
log "Drive it: python3 scripts/pilot.py screenshot|key|hold|click|clicknode|ui|state|quit"
# T-346: route Godot through the single resolver (scripts/godot-bin.sh) so the 4.6->4.7 cutover is
# one pin flip. The leading --env/--filesystem flags are consumed by the resolver (flatpak sandbox
# flags in 4.6 mode; real child env vars in native 4.7 mode).
GODOT_ARGS=(
	--env="AVALON_HOST=127.0.0.1"
	--env="AVALON_PORT=9200"
	--env="AVALON_TOKEN=$TOKEN"
	--env="AVALON_PILOT=1"
	--env="AVALON_PILOT_DIR=$PILOT_DIR"
	--env="AVALON_FREEZE_DAY=${AVALON_FREEZE_DAY:-}"
	--env="AVALON_PILOT_RESOLUTION=$RESOLUTION"
	--filesystem=/tmp
	--path "$CLIENT_DIR" --resolution "$RESOLUTION"
)
if [[ "$XVFB" == "1" ]] && command -v xvfb-run >/dev/null 2>&1; then
	# --auto-servernum picks a free :N so parallel lanes/leases don't collide on :99.
	nohup xvfb-run --auto-servernum -s "-screen 0 ${RESOLUTION}x24" \
		"$SCRIPT_DIR/godot-bin.sh" "${GODOT_ARGS[@]}" \
		> "$PILOT_DIR/client.log" 2>&1 &
elif [[ "$XVFB" == "1" ]]; then
	# xvfb-run absent but bare Xvfb is: start our own display manually.
	XVFB_DISPLAY_NUM=99
	while [[ -e "/tmp/.X${XVFB_DISPLAY_NUM}-lock" ]]; do XVFB_DISPLAY_NUM=$((XVFB_DISPLAY_NUM + 1)); done
	Xvfb ":$XVFB_DISPLAY_NUM" -screen 0 "${RESOLUTION}x24" &
	echo $! > "$PILOT_DIR/xvfb.pid"
	sleep 1
	DISPLAY=":$XVFB_DISPLAY_NUM" nohup "$SCRIPT_DIR/godot-bin.sh" "${GODOT_ARGS[@]}" \
		> "$PILOT_DIR/client.log" 2>&1 &
else
	nohup "$SCRIPT_DIR/godot-bin.sh" "${GODOT_ARGS[@]}" \
		> "$PILOT_DIR/client.log" 2>&1 &
fi
echo $! > "$PILOT_DIR/client.pid"
sleep 6
if grep -q "\[pilot\] active" "$PILOT_DIR/client.log"; then
	log "Pilot is up."
else
	log "WARNING: pilot banner not seen yet — check $PILOT_DIR/client.log"
	tail -5 "$PILOT_DIR/client.log"
fi
