#!/usr/bin/env bash
# test-dbd-parity.sh — T-701: the avalon-dbd sidecar must be byte-identical to the
# pg_query.sh subprocess path for the whole corpus (incl. the T-069 error/rollback
# cases), against the real dev Postgres.
#
# Starts its OWN sidecar on a test port with an ephemeral secret (never touches a
# dev-up sidecar), runs tools/db/dbd_parity.py, and kills the sidecar via PID file.
#
# Usage: test-dbd-parity.sh [--timing N]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
log() { echo "[test-dbd-parity] $*"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then set -a; source "$PROJECT_DIR/.env"; set +a; fi
if [[ -z "${AVALON_PG_PASSWORD:-}" ]]; then log "FATAL: AVALON_PG_PASSWORD not set (.env missing?)"; exit 1; fi
if ! pg_isready -q -h "${PG_HOST:-127.0.0.1}" -p "${PG_PORT:-5432}" 2>/dev/null; then
    log "FATAL: Postgres not reachable"; exit 1
fi

TEST_PORT="${AVALON_DBD_TEST_PORT:-9218}"
export AVALON_DBD_SECRET="$(openssl rand -hex 16)"
WORK_DIR="$(mktemp -d /tmp/avalon-dbd-parity.XXXXXX)"
PID_FILE="$WORK_DIR/dbd.pid"
DBD_LOG="$WORK_DIR/dbd.log"

cleanup() {
    if [[ -f "$PID_FILE" ]]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

log "starting sidecar on 127.0.0.1:$TEST_PORT (log: $DBD_LOG)"
python3 tools/db/avalon_dbd.py --port "$TEST_PORT" --pid-file "$PID_FILE" > "$DBD_LOG" 2>&1 &

ready=0
for _ in $(seq 1 50); do
    if grep -qF "listening on" "$DBD_LOG" 2>/dev/null; then ready=1; break; fi
    sleep 0.1
done
if [[ $ready -ne 1 ]]; then
    log "FATAL: sidecar failed to start"
    cat "$DBD_LOG"
    exit 1
fi

python3 tools/db/dbd_parity.py --port "$TEST_PORT" "$@"
rc=$?
if [[ $rc -eq 0 ]]; then
    log "PASS — sidecar output byte-identical to the subprocess path"
else
    log "FAIL (rc=$rc) — sidecar log follows"
    cat "$DBD_LOG"
fi
exit $rc
