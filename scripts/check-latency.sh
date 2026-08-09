#!/usr/bin/env bash
# check-latency.sh — Verify M0 latency exit criterion.
#
# Connects one client to the world server, sends a ping/pong latency probe,
# and asserts round-trip time is under threshold.
#   localhost target: < 100ms RTT   (default)
#   LAN target:       < 200ms RTT   (pass THRESHOLD_MS=200)
#
# Usage: ./scripts/check-latency.sh [THRESHOLD_MS]
# Exit: 0 = PASS, 1 = FAIL
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

THRESHOLD_MS="${1:-100}"
GODOT="org.godotengine.Godot"
WORLD_DIR="$PROJECT_DIR/server/world"
OUT="/tmp/latency-check.log"

log() { echo "[check-latency] $*"; }

# ── Load secret ───────────────────────────────────────────────
if [[ -f "$PROJECT_DIR/.env" ]]; then set -a; source "$PROJECT_DIR/.env"; set +a; fi
if [[ -z "${AVALON_JWT_SECRET:-}" ]]; then
  log "FATAL: AVALON_JWT_SECRET not set"; exit 1
fi

# ── Servers up? ───────────────────────────────────────────────
_started=false
servers_up() { ss -ulnp 2>/dev/null | grep -q ":9200" && ss -tlnp 2>/dev/null | grep -q ":9100"; }
if servers_up; then log "Using existing servers"; else
  log "Starting servers..."; bash scripts/dev-up.sh >/dev/null 2>&1; _started=true; sleep 4
fi
servers_up || { log "FATAL: servers not ready"; [[ "$_started" == true ]] && bash scripts/dev-down.sh >/dev/null 2>&1; exit 1; }

# ── Seed a token ──────────────────────────────────────────────
TOKEN=$(python3 - << 'PYEOF'
import hmac,hashlib,base64,json,time,subprocess,os
s=os.environ['AVALON_JWT_SECRET']
def b(d): return base64.urlsafe_b64encode(d).rstrip(b'=').decode()
h=b(json.dumps({'alg':'HS256','typ':'JWT'},separators=(',',':')).encode())
p=b(json.dumps({'sub':'lat_probe','iat':int(time.time()),'exp':int(time.time())+3600,'iss':'avalon'},separators=(',',':')).encode())
t=h+'.'+p+'.'+hmac.new(s.encode(),(h+'.'+p).encode(),hashlib.sha256).hexdigest()
sql="INSERT INTO auth.sessions (token,username,issued_at,expires_at,revoked) VALUES ('"+t+"','lat_probe',NOW(),NOW()+INTERVAL '1 hour',false) ON CONFLICT (token) DO UPDATE SET revoked=false;"
subprocess.run(['bash','-c','podman exec avalon-postgres psql -U avalon -d avalon -c "'+sql+'"'],check=True,capture_output=True)
print(t)
PYEOF
)
[[ -z "$TOKEN" ]] && { log "FATAL: token seed failed"; [[ "$_started" == true ]] && bash scripts/dev-down.sh >/dev/null 2>&1; exit 1; }

# ── Run probe client ──────────────────────────────────────────
log "Probing RTT (threshold ${THRESHOLD_MS}ms)..."
timeout 15 flatpak run --env="AVALON_HOST=127.0.0.1" --env="AVALON_PORT=9200" \
  --env="AVALON_TOKEN=$TOKEN" --env="AVALON_MOVE_DURATION=2.0" \
  --filesystem="$PROJECT_DIR" --filesystem=/tmp \
  "$GODOT" --headless --path "$WORLD_DIR" \
  --scene res://tests/test_client.tscn > "$OUT" 2>&1

RESULT=$(grep "result:" "$OUT" | tail -1 | sed 's/.*result: //')
RTT=$(echo "$RESULT" | grep -oE '"ping_rtt_ms":[0-9.-]+' | cut -d: -f2)

[[ "$_started" == true ]] && { log "Stopping servers..."; bash scripts/dev-down.sh >/dev/null 2>&1; }

if [[ -z "$RTT" || "$RTT" == "-1" ]]; then
  log "FAIL — no RTT measured (pong not received). Result: $RESULT"; exit 1
fi

# integer compare (RTT may be float like 7.0)
RTT_INT=${RTT%.*}
log "Measured ping RTT: ${RTT}ms"
if (( RTT_INT < THRESHOLD_MS )); then
  log "PASS — RTT ${RTT}ms < ${THRESHOLD_MS}ms"
  exit 0
else
  log "FAIL — RTT ${RTT}ms >= ${THRESHOLD_MS}ms"
  exit 1
fi
