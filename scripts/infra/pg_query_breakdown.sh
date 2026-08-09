#!/usr/bin/env bash
# T-701 Step 0 — attribute the per-query cost of the subprocess-per-query DB path.
#
# The ticket measures ~7 ms warm / ~155 ms cold per round-trip and concludes the fix is a persistent
# connection. That is probably right, but "7 ms" is an aggregate: it bundles bash startup, one
# fork+exec of `base64` PER PARAMETER, a `mktemp`, psql's own startup, the TCP connect + auth
# handshake, and the actual server time. Those have very different fixes — a sidecar removes the
# connect, but only removing the subprocess removes the rest. This script splits them so T-701 picks
# its approach against a breakdown instead of a single number.
#
# Usage: scripts/infra/pg_query_breakdown.sh [iterations]   (default 50)
# Requires: AVALON_PG_PASSWORD (source .env), a reachable Postgres.

set -euo pipefail

ITER="${1:-50}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_QUERY="$SCRIPT_DIR/pg_query.sh"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-avalon}"
DATABASE="${DATABASE:-avalon}"

if [[ -z "${AVALON_PG_PASSWORD:-}" ]]; then
    echo "ERROR: AVALON_PG_PASSWORD not set — run: set -a; . ./.env; set +a" >&2
    exit 1
fi
export PGPASSWORD="$AVALON_PG_PASSWORD"

# Millisecond wall clock for a command repeated $ITER times, reported per-iteration.
bench() {
    local label="$1"; shift
    local start end
    start=$(date +%s%N)
    for ((i = 0; i < ITER; i++)); do "$@" >/dev/null 2>&1; done
    end=$(date +%s%N)
    printf '%-46s %8.2f ms/op\n' "$label" "$(bc -l <<<"($end - $start) / $ITER / 1000000")"
}

echo "=== T-701 Step 0: per-query cost attribution (n=$ITER) ==="
echo

echo "--- what the master actually pays today ---"
bench "pg_query.sh, 0 params (full path)" \
    "$PG_QUERY" -Q "$(printf 'SELECT 1;' | base64 -w0)" "$DATABASE"
bench "pg_query.sh, 3 params (full path)" \
    "$PG_QUERY" \
    -w "a=$(printf 'x' | base64 -w0)" \
    -w "b=$(printf 'y' | base64 -w0)" \
    -w "c=$(printf 'z' | base64 -w0)" \
    -Q "$(printf "SELECT :'a', :'b', :'c';" | base64 -w0)" "$DATABASE"
echo

echo "--- component costs ---"
bench "bare psql -c (startup + connect + query)" \
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE" -A -q -c 'SELECT 1;'
bench "psql --version (process startup, NO connect)" psql --version
bench "bash -c true (interpreter startup only)" bash -c true
bench "base64 -d (one param's decode)" bash -c 'printf dGVzdA== | base64 -d'
bench "mktemp + rm (the SQL temp file)" \
    bash -c 'f=$(mktemp /tmp/pgq.XXXXXX.sql); rm -f "$f"'
echo

echo "--- the floor: one connection, N queries (what a persistent conn would pay) ---"
# Build an N-statement script and run it down ONE psql connection. Divided by N this is
# per-query server+protocol time with connection and process cost amortised to ~zero.
SCRIPT_FILE="$(mktemp /tmp/pgq_bench.XXXXXX.sql)"
trap 'rm -f "$SCRIPT_FILE"' EXIT
for ((i = 0; i < ITER; i++)); do echo 'SELECT 1;' >> "$SCRIPT_FILE"; done
start=$(date +%s%N)
psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE" -A -q -f "$SCRIPT_FILE" >/dev/null 2>&1
end=$(date +%s%N)
printf '%-46s %8.2f ms/op\n' "persistent connection, per query" \
    "$(bc -l <<<"($end - $start) / $ITER / 1000000")"
echo
echo "Read: (full path) - (persistent conn) = what a persistent connection can actually remove."
