#!/usr/bin/env bash
# pg_query.sh — secure psql wrapper for Avalon master server.
#
# Usage: pg_query.sh [-v name=value...] [-w name=base64value...] [-Q base64sql] <sql_query> [database]
#
# T-517: native Godot 4.7's OS.execute re-tokenizes argv (strips embedded double
# quotes, splits on the surrounding spaces), which mangled JSON param values and
# could push a split fragment into the positional <sql_query>/[database] slots.
# database.gd therefore sends params as -w name=<base64> and the SQL as -Q <base64>
# (base64 has no quotes/spaces, so it survives any tokenizer; -Q is an unambiguous
# flag, so a stray positional can never be read as the database). The plain
# positional form stays supported for shell callers (dev-up, migrations, testers).
#
# Reads AVALON_PG_PASSWORD from environment (not from config).
# Reads PG_HOST, PG_PORT, PG_USER from environment or uses defaults.
#
# -v pairs are forwarded to psql as distinct argv elements (never
# shell-string concat). SQL is passed via -f as its own element.
#
# Output: header TSV line + data TSV lines (no footer). Stderr for errors.
# Exit codes: 0 = success, 1 = connection/query failure.
#
# FLATPAK SANDBOX: when called from inside the Godot Flatpak sandbox,
# psql is not on PATH (not in the SDK). We detect the sandbox via
# FLATPAK_ID and run psql on the HOST via flatpak-spawn --host, passing
# the password explicitly with --env=PGPASSWORD (plain env vars are NOT
# inherited across the host boundary, but --env= forwards explicitly).
# All other logic is identical on host and sandbox.

set -euo pipefail

# Parse argv: collect -v / -w pairs and -Q, remaining args are SQL + optional database
# (or database only, when the SQL came in via -Q).
VARS=()
SQL_QUERY=""
SQL_FROM_FLAG=0
DATABASE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v)
            [[ -n "${2:-}" ]] || { echo "ERROR: -v requires argument" >&2; exit 1; }
            VARS+=("-v" "$2")
            shift 2
            ;;
        -w)
            # base64-armored param: -w name=<base64(value)> → psql -v name=value
            [[ -n "${2:-}" && "$2" == *=* ]] || { echo "ERROR: -w requires name=base64value" >&2; exit 1; }
            decoded="$(printf '%s' "${2#*=}" | base64 -d)" \
                || { echo "ERROR: -w value is not valid base64" >&2; exit 1; }
            VARS+=("-v" "${2%%=*}=${decoded}")
            shift 2
            ;;
        -Q)
            # base64-armored SQL (unambiguous flag — cannot be misread as the database)
            [[ -n "${2:-}" ]] || { echo "ERROR: -Q requires argument" >&2; exit 1; }
            SQL_QUERY="$(printf '%s' "$2" | base64 -d)" \
                || { echo "ERROR: -Q value is not valid base64" >&2; exit 1; }
            SQL_FROM_FLAG=1
            shift 2
            ;;
        *)
            if [[ -z "$SQL_QUERY" && "$SQL_FROM_FLAG" -eq 0 ]]; then
                SQL_QUERY="$1"
            else
                DATABASE="$1"
            fi
            shift
            ;;
    esac
done

[[ -n "$SQL_QUERY" ]] || { echo "Usage: pg_query.sh [-v name=value...] [-w name=base64value...] [-Q base64sql] <sql_query> [database]" >&2; exit 1; }

DATABASE="${DATABASE:-avalon}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-avalon}"

if [[ -z "${AVALON_PG_PASSWORD:-}" ]]; then
    echo "ERROR: AVALON_PG_PASSWORD not set" >&2
    exit 1
fi

# SQL goes to psql's STDIN via `-f -`. It must ride -f (not -c) because -c does NOT expand :'var'
# in PG 18+ — but -f accepts `-` for stdin, so the temp file the original version wrote is not
# needed. T-701 measured the mktemp+trap+rm at 1.07 ms/op, ~16% of a 6.62 ms round trip (n=100:
# stdin 4.67 ms/op vs temp-file 5.18 ms/op). Verified that `:'var'` expansion behaves identically
# over stdin. The pipe is built at each call site below so `set -o pipefail` still surfaces psql's
# exit status (ON_ERROR_STOP=1 exits 3 on the first SQL error — T-069 depends on that propagating).

# psql flags (identical on host and sandbox):
#   -A -F tab     : unaligned, tab-separated output
#   -P footer=off : no row-count footer
#   no -t flag    : keep the header row for TSV->dict parsing in database.gd
#   -f            : client-side :'param' expansion with proper SQL quoting
#   -q            : TD-003 — suppress command tags ("UPDATE 1"); they parse as phantom
#                   TSV rows in database.gd for INSERT/UPDATE ... RETURNING queries.
#   ON_ERROR_STOP : T-069 — without it a SQL error in a -f script exits 0 and
#                   every DB write could silently fail while the game reported
#                   success. With it psql exits 3 on the first error (and an
#                   open BEGIN block is rolled back on disconnect).
psql_args=(
    -h "$PG_HOST"
    -p "$PG_PORT"
    -U "$PG_USER"
    -d "$DATABASE"
    -A -F $'\t'
    -P footer=off
    -q
    -v ON_ERROR_STOP=1
    "${VARS[@]}"
    -f -
)

# Inside the Flatpak sandbox psql isn't available; run it on the host.
if [[ -n "${FLATPAK_ID:-}" ]] && command -v flatpak-spawn >/dev/null 2>&1; then
    if ! printf '%s\n' "$SQL_QUERY" \
        | flatpak-spawn --host --env=PGPASSWORD="$AVALON_PG_PASSWORD" psql "${psql_args[@]}"; then
        echo "ERROR: psql query failed (sandbox->host)" >&2
        exit 1
    fi
else
    export PGPASSWORD="$AVALON_PG_PASSWORD"
    if ! printf '%s\n' "$SQL_QUERY" | psql "${psql_args[@]}"; then
        unset PGPASSWORD
        echo "ERROR: psql query failed (host)" >&2
        exit 1
    fi
    unset PGPASSWORD
fi

exit 0
