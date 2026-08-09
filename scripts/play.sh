#!/usr/bin/env bash
# play.sh — bring up the stack, seed a player, and launch the client WITH A DISPLAY so you can play.
#
# Use this for play-testing the 3D client (T-053+): WASD to move (T-054). Run it on a machine with a
# display. Servers stay up after you close the client; run scripts/dev-down.sh to stop them.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# GPU graphics guard (595.84 Blackwell Xid-79 wait-mode) — refuse to render locally while locked.
bash "$PROJECT_DIR/scripts/ops/gpu-graphics-guard.sh" || exit 1

CLIENT_DIR="$PROJECT_DIR/client"
USER_NAME="${1:-player}"   # optional: a character name (defaults to "player")

log() { echo "[play] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1"; }

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

servers_up() {
	ss -ulnp 2>/dev/null | grep -q ":9200" && ss -tlnp 2>/dev/null | grep -q ":9100"
}
if servers_up; then
	log "Using existing servers"
else
	log "Starting servers (dev-up)..."
	bash scripts/dev-up.sh >/dev/null 2>&1
	sleep 4
fi
servers_up || { log "FATAL: servers not ready on 9100/9200"; exit 1; }

TOKEN="$(python3 - << PYEOF
import base64, hashlib, hmac, json, os, time
secret = os.environ["AVALON_JWT_SECRET"]
def b64url(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
header = b64url(json.dumps({"alg":"HS256","typ":"JWT"},separators=(",",":")).encode())
payload = b64url(json.dumps({"sub":"$USER_NAME","iat":int(time.time()),
    "exp":int(time.time())+3600,"iss":"avalon"},separators=(",",":")).encode())
sig = hmac.new(secret.encode(), (header+"."+payload).encode(), hashlib.sha256).hexdigest()
print(header+"."+payload+"."+sig)
PYEOF
)"
[[ -z "$TOKEN" ]] && { log "FATAL: token gen failed"; exit 1; }

log "Seeding session + character for '$USER_NAME'..."
psql_exec "INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked)
	VALUES ('$TOKEN', '$USER_NAME', NOW(), NOW() + INTERVAL '1 hour', false)
	ON CONFLICT (token) DO UPDATE SET username='$USER_NAME', revoked=false;" >/dev/null
psql_exec "INSERT INTO chars.characters (username) VALUES ('$USER_NAME')
	ON CONFLICT (username) DO NOTHING;" >/dev/null

GODOT_BIN="godot"
command -v godot >/dev/null 2>&1 || GODOT_BIN="flatpak run org.godotengine.Godot"
log "Launching client as '$USER_NAME' — WASD to move; close the window to stop."
log "(servers stay up; run scripts/dev-down.sh to stop them)"
AVALON_HOST=127.0.0.1 AVALON_PORT=9200 AVALON_TOKEN="$TOKEN" $GODOT_BIN --path "$CLIENT_DIR"
