#!/usr/bin/env bash
# Issue a test session token for local development.
#
# Usage: ./scripts/issue-test-token.sh [username]
#   Defaults username to "dev_test" if not provided.
#
# Prints a 32-character lowercase hex token to stdout.
# Also registers the token in Postgres auth.sessions (if master is running).
#
# Requires: websocat (available at ~/.cargo/bin/websocat)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

USERNAME="${1:-dev_test}"
MASTER_PORT=9100
MASTER_HOST="127.0.0.1"

# ── Generate 32-char lowercase hex token ────────────────────────────
TOKEN=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p | tr -d '\n')

if [[ ${#TOKEN} -ne 32 ]]; then
    echo "[token] FATAL: generated token is not 32 chars (got ${#TOKEN}): $TOKEN" >&2
    exit 1
fi

# ── Try to register with master server ──────────────────────────────
WEBSOCAT=""
if command -v websocat >/dev/null 2>&1; then
    WEBSOCAT="websocat"
elif [[ -f "$HOME/.cargo/bin/websocat" ]]; then
    WEBSOCAT="$HOME/.cargo/bin/websocat"
fi

MASTER_UP=false
if [[ -n "$WEBSOCAT" ]]; then
    # Try to connect and send issue_session RPC
    RPC_REQUEST=$(printf '{"method":"issue_session","params":{"username":"%s","token":"%s"},"id":"1"}' "$USERNAME" "$TOKEN")
    RESPONSE=$("$WEBSOCAT" "ws://$MASTER_HOST:$MASTER_PORT" -t <<< "$RPC_REQUEST" 2>/dev/null) || true

    if [[ -n "$RESPONSE" ]]; then
        MASTER_UP=true
    fi
fi

if [[ "$MASTER_UP" == "true" ]]; then
    echo "[token] Issued for '$USERNAME', registered with master at $MASTER_HOST:$MASTER_PORT"
else
    echo "[token] WARNING: master not running at $MASTER_HOST:$MASTER_PORT — token is local-only, will not persist"
fi

# ── Print token to stdout ───────────────────────────────────────────
echo "$TOKEN"
exit 0
