#!/usr/bin/env bash
# test-remote-entities-loop.sh — two-client E2E guard for T-055.
#
# A real client (observer, headless AVALON_OBSERVE mode) must RENDER another player from the positions
# broadcast. The single-client net-smoke can't see this — and didn't catch the _receive_message no-op
# that silently dropped the ENTIRE positions stream (no remote players, no mobs, no local reconcile).
# This harness runs the real client + a second moving player and asserts the observer saw >= 1 remote
# player. Exit 0 = pass, 1 = fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
RESULT="/tmp/avalon-remote-entities.json"
OBS_LOG="/tmp/avalon-remote-observer.log"
MOVER_LOG="/tmp/avalon-remote-mover.log"

log() { echo "[test-remote-entities-loop] $*"; }
psql_exec() { podman exec -i avalon-postgres psql -U avalon -d avalon -c "$1" >/dev/null 2>&1; }

if [[ -f "$PROJECT_DIR/.env" ]]; then set -a; source "$PROJECT_DIR/.env"; set +a; fi
[[ -z "${AVALON_JWT_SECRET:-}" ]] && { log "FATAL: AVALON_JWT_SECRET unset"; exit 1; }
export AVALON_JWT_SECRET
# T-373: this guard asserts the observer sees the mover, which requires both inside the AOI radius.
# Login dispersion would scatter them across hubs (>80 m apart), so pin spawn to origin here (the
# deterministic escape hatch dev-up forwards to the world server). A stale already-up stack keeps its
# old spawn mode — reboot the stack (dev-down + dev-up) if this harness was preceded by a dispersed run.
export AVALON_SPAWN_FIXED=1

gen_token() {
	python3 - "$1" <<'PY'
import base64, hashlib, hmac, json, os, sys, time
s = os.environ["AVALON_JWT_SECRET"]; u = sys.argv[1]
b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
h = b(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
p = b(json.dumps({"sub": u, "iat": int(time.time()), "exp": int(time.time()) + 3600, "iss": "avalon"}, separators=(",", ":")).encode())
print(h + "." + p + "." + hmac.new(s.encode(), (h + "." + p).encode(), hashlib.sha256).hexdigest())
PY
}

servers_up() { ss -ltn 2>/dev/null | grep -q ":9100" && ss -ulnp 2>/dev/null | grep -q ":9200"; }
if ! servers_up; then
	log "starting servers (dev-up)..."
	bash scripts/dev-up.sh >/dev/null 2>&1
	sleep 4
fi
servers_up || { log "FATAL: servers not up on 9100/9200"; exit 1; }

for U in obsviewer obsmover; do
	T="$(gen_token "$U")"
	[[ "$U" == "obsviewer" ]] && TOK_VIEWER="$T" || TOK_MOVER="$T"
	psql_exec "INSERT INTO auth.sessions (token,username,issued_at,expires_at,revoked)
		VALUES ('$T','$U',NOW(),NOW()+INTERVAL '1 hour',false)
		ON CONFLICT (token) DO UPDATE SET username='$U',revoked=false;"
	psql_exec "INSERT INTO chars.characters (username) VALUES ('$U') ON CONFLICT (username) DO NOTHING;"
done

rm -f "$RESULT" "$OBS_LOG" "$MOVER_LOG"
log "observer (real client) + a second moving player..."
timeout 30 flatpak run \
	--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=9200" --env="AVALON_TOKEN=$TOK_VIEWER" \
	--env="AVALON_OBSERVE=1" --env="AVALON_OBSERVE_SECS=10" --env="AVALON_RESULT_FILE=$RESULT" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	org.godotengine.Godot --headless --path client --scene res://scenes/main.tscn >"$OBS_LOG" 2>&1 &
OBS_PID=$!
sleep 2
timeout 14 flatpak run \
	--env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=9200" --env="AVALON_TOKEN=$TOK_MOVER" \
	--env="AVALON_MOVE_DURATION=9" --env="AVALON_MOVE_SPEED=30" --env="AVALON_RESULT_FILE=/tmp/obsmover.json" \
	--env="AVALON_MOVE_STRAIGHT=1" --env="AVALON_MOVE_ANGLE_DEG=0" \
	--filesystem="$PROJECT_DIR" --filesystem=/tmp \
	org.godotengine.Godot --headless --path server/world --scene res://tests/test_client.tscn >"$MOVER_LOG" 2>&1 &
wait "$OBS_PID" 2>/dev/null

python3 - "$RESULT" <<'PY'
import json, sys
try:
	d = json.load(open(sys.argv[1]))
except Exception as e:
	print("[test-remote-entities-loop] FAIL — no observer result (%s)" % e); sys.exit(1)
players = d.get("max_remote_players", 0)
ents = d.get("max_remote_entities", 0)
in_view = d.get("remote_player_in_view", False)
# T-727: the moving player must also FACE the way it moves on the observer's client. dot ~ -1 is the
# shipped defect (body translating forward, rig facing backwards); 0 samples means the mover never
# ran in view, so the guard never actually ran — treat that as a failure, not a silent pass.
samples = d.get("facing_samples", 0)
dot = d.get("min_facing_dot", -1.0)
facing_ok = d.get("facing_matches_travel", False) and samples >= 1
# Gate: a remote player must spawn AND fall inside the observer's camera frustum (ADR 0009).
if players >= 1 and in_view and facing_ok:
	print("[test-remote-entities-loop] PASS — observer rendered %d remote player(s), %d entit(ies), "
	      "a remote player was in the camera's view (perception gate), and its facing tracked its "
	      "travel over %d running frame(s) (worst dot(forward, velocity) = %.3f, T-727)"
	      % (players, ents, samples, dot))
	sys.exit(0)
print("[test-remote-entities-loop] FAIL — remote_players=%d in_view=%s facing_ok=%s "
      "(facing_samples=%d min_dot=%.3f) — broadcast→render→view/facing broken"
      % (players, in_view, facing_ok, samples, dot))
sys.exit(1)
PY
