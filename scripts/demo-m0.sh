#!/usr/bin/env bash
# demo-m0.sh — Prove M0 gameplay exit criterion.
#
# Demonstrates: two clients connect to world, see each other move.
# Gateway routing is bypassed (deferred to T-014). Tokens are JWTs
# seeded directly into auth.sessions (master's issue_session is a
# gateway-dependent stub in M0, so we seed signed JWTs the same way
# the e2e tests do).
#
# Usage: ./scripts/demo-m0.sh
# Exit: 0 = PASS, 1 = FAIL
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GODOT="org.godotengine.Godot"
WORLD_DIR="$PROJECT_DIR/server/world"
A_LOG="/tmp/demo-m0-a.log"
B_LOG="/tmp/demo-m0-b.log"

log() { echo "[demo-m0] $*"; }

# ── Load secret ───────────────────────────────────────────────
if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi
if [[ -z "${AVALON_JWT_SECRET:-}" ]]; then
  log "FATAL: AVALON_JWT_SECRET not set (.env missing?)"
  exit 1
fi

# ── Pre-flight: servers running? ──────────────────────────────
_started_servers=false
servers_up() {
  ss -ulnp 2>/dev/null | grep -q ":9200" && \
  ss -tlnp 2>/dev/null | grep -q ":9100"
}
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
  [[ "$_started_servers" == "true" ]] && bash scripts/dev-down.sh >/dev/null 2>&1
  exit 1
fi
log "Servers ready (9001, 9100, 9200)"

# ── Seed two JWT tokens ───────────────────────────────────────
python3 - << 'PYEOF'
import hmac, hashlib, base64, json, time, subprocess, os
secret = os.environ['AVALON_JWT_SECRET']
def b64url(d): return base64.urlsafe_b64encode(d).rstrip(b'=').decode()
def make_jwt(sub):
    h = b64url(json.dumps({'alg':'HS256','typ':'JWT'},separators=(',',':')).encode())
    p = b64url(json.dumps({'sub':sub,'iat':int(time.time()),'exp':int(time.time())+3600,'iss':'avalon'},separators=(',',':')).encode())
    sig = hmac.new(secret.encode(), (h+'.'+p).encode(), hashlib.sha256).hexdigest()
    return h+'.'+p+'.'+sig
psql = "podman exec avalon-postgres psql -U avalon -d avalon -c"
toks = {}
for sub in ('player_a','player_b'):
    t = make_jwt(sub); toks[sub] = t
    sql = ("INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked) "
           "VALUES ('"+t+"', '"+sub+"', NOW(), NOW() + INTERVAL '1 hour', false) "
           "ON CONFLICT (token) DO UPDATE SET username = '"+sub+"', revoked = false;")
    subprocess.run(['bash','-c', psql+' "'+sql+'"'], check=True, capture_output=True)
with open('/tmp/demo-m0-tokens.env','w') as f:
    f.write("TOKEN_A="+toks['player_a']+"\n")
    f.write("TOKEN_B="+toks['player_b']+"\n")
PYEOF
if [[ ! -f /tmp/demo-m0-tokens.env ]]; then
  log "FATAL: token seeding failed"
  [[ "$_started_servers" == "true" ]] && bash scripts/dev-down.sh >/dev/null 2>&1
  exit 1
fi
source /tmp/demo-m0-tokens.env
log "Token A: ${TOKEN_A:0:16}... (player_a)"
log "Token B: ${TOKEN_B:0:16}... (player_b)"

# ── Launch two clients ────────────────────────────────────────
log "Launching two test clients..."
run_client() {
  local tok="$1" seed="$2" out="$3"
  flatpak run --env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=9200" \
    --env="AVALON_TOKEN=$tok" --env="AVALON_MOVE_DURATION=3.0" \
    --env="AVALON_MOVE_SPEED=50.0" --env="AVALON_MOVE_SEED=$seed" \
    --filesystem="$PROJECT_DIR" --filesystem=/tmp \
    "$GODOT" --headless --path "$WORLD_DIR" \
    --scene res://tests/test_client.tscn > "$out" 2>&1
}
run_client "$TOKEN_A" 42 "$A_LOG" &
PID_A=$!
sleep 0.5
run_client "$TOKEN_B" 99 "$B_LOG" &
PID_B=$!
wait $PID_A; wait $PID_B

# ── Verify ────────────────────────────────────────────────────
RESULT_A=$(grep "result:" "$A_LOG" | tail -1 | sed 's/.*result: //')
RESULT_B=$(grep "result:" "$B_LOG" | tail -1 | sed 's/.*result: //')

pass_of() { echo "$1" | grep -q '"pass":true' && echo true || echo false; }
moves_of() { echo "$1" | grep -oE '"moves_sent":[0-9]+' | cut -d: -f2; }
peers_of() { echo "$1" | grep -oE '"other_peers_seen":\[[^]]*\]' ; }

PASS_A=$(pass_of "$RESULT_A"); PASS_B=$(pass_of "$RESULT_B")
log "Client A: pass=$PASS_A, moves_sent=$(moves_of "$RESULT_A"), $(peers_of "$RESULT_A")"
log "Client B: pass=$PASS_B, moves_sent=$(moves_of "$RESULT_B"), $(peers_of "$RESULT_B")"
log ""

# ── Cleanup ───────────────────────────────────────────────────
if [[ "$_started_servers" == "true" ]]; then
  log "Stopping servers..."
  bash scripts/dev-down.sh >/dev/null 2>&1
fi

if [[ "$PASS_A" == "true" && "$PASS_B" == "true" ]]; then
  log "M0 GAMEPLAY criterion: PASS"
  log "(gateway routing deferred to T-014)"
  log ""
  log "A saw B move, B saw A move."
  exit 0
else
  log "FAILURE — one or both clients did not observe the other"
  log "Client A result: $RESULT_A"
  log "Client B result: $RESULT_B"
  log "M0 GAMEPLAY criterion: FAIL"
  exit 1
fi
