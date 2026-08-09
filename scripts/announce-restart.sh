#!/usr/bin/env bash
# T-509: announce an in-game maintenance-restart countdown from the CLI. Sends the authenticated
# `announce` verb to the world's LOOPBACK-ONLY ops channel (the same admin seam as the GM panel) —
# this is never a client-reachable verb. The world broadcasts the countdown beats (T-10m/5m/2m/1m/
# 30s + "beginning now") to every connected client so a scheduled restart never reads as a crash.
#
# Usage:  scripts/announce-restart.sh <minutes> "<reason>"
# Needs:  AVALON_OPS_SECRET (and optional AVALON_OPS_PORT, default 9215) — see infra/gm/secrets.env:
#           source infra/gm/secrets.env && scripts/announce-restart.sh 10 "deploying the build gate"
set -euo pipefail

MINUTES="${1:?usage: announce-restart.sh <minutes> \"<reason>\"}"
REASON="${2:?usage: announce-restart.sh <minutes> \"<reason>\"}"
[[ "$MINUTES" =~ ^[0-9]+$ && "$MINUTES" -ge 1 ]] || {
	echo "minutes must be a positive integer" >&2
	exit 2
}
: "${AVALON_OPS_SECRET:?set AVALON_OPS_SECRET (see infra/gm/secrets.env)}"
PORT="${AVALON_OPS_PORT:-9215}"

python3 - "$AVALON_OPS_SECRET" "$PORT" "$MINUTES" "$REASON" <<'PY'
import json, socket, sys
secret, port, minutes, reason = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
req = {"secret": secret, "actor": "cli-announce-restart", "verb": "announce",
       "params": {"minutes": minutes, "reason": reason}}
try:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
        s.sendall((json.dumps(req) + "\n").encode())
        resp = json.loads(s.recv(8192).decode())
except OSError as exc:
    print(f"could not reach the ops channel on 127.0.0.1:{port} ({exc}) — is the world up?", file=sys.stderr)
    sys.exit(1)
if resp.get("ok"):
    print(f"maintenance countdown started: {minutes}m — {reason}")
else:
    print(f"announce failed: {resp.get('error', 'unknown')}", file=sys.stderr)
    sys.exit(1)
PY
