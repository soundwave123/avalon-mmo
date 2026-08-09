#!/usr/bin/env bash
# Launch all three Avalon servers for local development.
#
# Servers started (in dependency order):
#   master   ws://0.0.0.0:9100  (must start first — gateway and world depend on it)
#   gateway  ws://0.0.0.0:9001  (auth/login/refresh)
#   world    enet://0.0.0.0:9200 (zone server, connects to master)
#
# Kill:   ./scripts/dev-down.sh
# Logs:   /tmp/avalon-dev/{gateway,master,world}.log
#
# Env vars (loaded from .env file in project root if present):
#   AVALON_JWT_SECRET            — JWT signing secret (required for gateway + master)
#   AVALON_JWT_REFRESH_SECRET    — Refresh token secret (required for gateway)
#   AVALON_JWT_TTL_SECONDS       — Token lifetime (default: 7200)
#   AVALON_PG_PASSWORD           — Postgres password (required for master)
#   AVALON_AUTH_MODE             — Gateway auth mode: accounts (default) or dev (harnesses only)
#   AVALON_PORT                  — World server ENet port (default: 9200)
#   AVALON_OPS_SECRET            — GM ops-channel secret (unset = listener disabled)
#   AVALON_OPS_PORT              — Loopback-only GM ops TCP port (default: 9215)
#   AVALON_DBD_SECRET            — avalon-dbd sidecar secret (unset = ephemeral per launch)
#   AVALON_DBD_PORT              — Loopback-only DB sidecar TCP port (default: 9217)
#   AVALON_DB_DRIVER             — DB driver: sidecar (default) or subprocess
#
# Pre-requisites:
#   - Postgres running on localhost:5432 (master refuses to start without it)
#   - AVALON_JWT_SECRET set (gateway and master refuse without it)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Port definitions ────────────────────────────────────────────────
GATEWAY_PORT=9001
MASTER_PORT=9100
WORLD_PORT="${AVALON_PORT:-9200}"

# ── Work directory for logs ─────────────────────────────────────────
WORK_DIR="/tmp/avalon-dev"
mkdir -p "$WORK_DIR"

# ── Load .env if present ────────────────────────────────────────────
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
    echo "[dev-up] Loaded .env from $PROJECT_DIR"
elif [[ -n "${AVALON_JWT_SECRET:-}" ]]; then
    echo "[dev-up] Using AVALON_JWT_SECRET from current shell environment"
else
    echo "[dev-up] WARNING: No .env file found and AVALON_JWT_SECRET not set"
    echo "[dev-up] Gateway and master will refuse to start without it."
    echo "[dev-up] Copy .env.example to .env and set real secrets, or export AVALON_JWT_SECRET."
    echo "[dev-up] Continuing — servers that need secrets will fail fast with clear errors."
fi

# ── Resolve flatpak + Godot ─────────────────────────────────────────
# Only the flatpak pin (the 4.6 live default) needs the flatpak runtime; the native 4.7 pin does
# not (T-346). Gate the precheck on the pin so a post-cutover machine without flatpak still boots.
if [[ "${AVALON_GODOT_PIN:-flatpak-4.6}" == flatpak-* ]] && ! command -v flatpak >/dev/null 2>&1; then
    echo "[dev-up] FATAL: flatpak not found (pin=${AVALON_GODOT_PIN:-flatpak-4.6})"
    exit 2
fi

# T-346: route Godot through the single resolver (scripts/godot-bin.sh) so the 4.6->4.7 cutover is
# one pin flip. It re-inserts `flatpak run` + the app-id (flatpak mode) or converts --env=/--
# filesystem= for the native 4.7 binary. --env= flags still pass secrets; --filesystem= grants FS.
GODOT_BIN="$SCRIPT_DIR/godot-bin.sh"
FLATPAK_BASE="$GODOT_BIN --filesystem=$PROJECT_DIR --filesystem=/tmp"
echo "[dev-up] Godot: via $GODOT_BIN (pin ${AVALON_GODOT_PIN:-flatpak-4.6})"

# ── Check Postgres ──────────────────────────────────────────────────
PG_OK=false
if command -v pg_isready >/dev/null 2>&1; then
    # -h/-p: the dev Postgres is the podman container on TCP 127.0.0.1:5432 — bare pg_isready
    # probes the Unix socket and reads FALSE forever (it silently gated the T-398 migration
    # hook off on its first live boot; previously it only mis-printed the warning below).
    if pg_isready -q -h "${PG_HOST:-127.0.0.1}" -p "${PG_PORT:-5432}" 2>/dev/null; then
        PG_OK=true
    fi
fi
if [[ "$PG_OK" != "true" ]]; then
    echo "[dev-up] WARNING: Postgres is not running or not reachable on localhost:5432"
    echo "[dev-up] Master server will fail to start (requires DB connectivity)."
    echo "[dev-up] Start with: sudo systemctl start postgresql   (or your distro's equivalent)"
fi

# ── Apply pending DB migrations (T-398) ─────────────────────────────────────
# A stack that boots must have a DB that matches its code. apply-migrations.sh tracks
# applied migrations in infra.schema_migrations and applies only the missing ones, hard-
# stopping on the first failure. A failed/behind migration ABORTS the launch — never boot
# servers against a half-migrated schema (the dev DB once fell 9 migrations behind silently).
if [[ "$PG_OK" == "true" ]]; then
    echo "[dev-up] Applying pending DB migrations..."
    if ! bash "$SCRIPT_DIR/apply-migrations.sh"; then
        echo "[dev-up] FATAL: migration failed (see the failing filename above); aborting launch."
        exit 3
    fi

    # ── Boot smoke: exercise the psql NULL-param boundary (T-398 §5) ─────────
    # The psql -v binding has bitten twice: string-typed rows (858a10e) and null params
    # rendered as the literal text "<null>" (2c5baa3). Schema-correct is not enough — drive
    # one NULL INSERT + one read-back through pg_query.sh every boot so the boundary itself
    # is tested, not just the schema. A NULL that lands as text or a bad read-back aborts.
    PGQ="bash $SCRIPT_DIR/infra/pg_query.sh"
    $PGQ "CREATE SCHEMA IF NOT EXISTS infra;
CREATE TABLE IF NOT EXISTS infra.boot_smoke (id SERIAL PRIMARY KEY, note TEXT, nullable_col INT);
DELETE FROM infra.boot_smoke;" >/dev/null 2>&1 || { echo "[dev-up] FATAL: boot smoke setup failed"; exit 3; }
    # NULLIF(:'n','') turns an empty param into a genuine SQL NULL for the nullable INT column;
    # if the boundary mangled it to the text "<null>" the ::int cast would error here.
    if ! $PGQ -v n="" "INSERT INTO infra.boot_smoke (note, nullable_col)
         VALUES ('boot', NULLIF(:'n','')::int)" >/dev/null 2>&1; then
        echo "[dev-up] FATAL: boot smoke NULL-param INSERT failed (psql binding boundary broken)"
        exit 3
    fi
    # Read back: note must be 'boot', nullable_col must come back as the empty TSV field (NULL).
    SMOKE_NOTE=$($PGQ "SELECT note FROM infra.boot_smoke WHERE nullable_col IS NULL ORDER BY id DESC LIMIT 1" \
        2>/dev/null | tail -1)
    if [[ "$SMOKE_NOTE" != "boot" ]]; then
        echo "[dev-up] FATAL: boot smoke read-back failed (got '$SMOKE_NOTE', expected 'boot')"
        exit 3
    fi
    echo "[dev-up] Boot smoke OK — psql NULL-param boundary healthy."
fi

# ── Launch avalon-dbd persistent-connection DB sidecar (T-701) ──────
# One warm psycopg2 connection replaces subprocess-per-query (~6.8 -> ~0.17 ms/op).
# The stale sidecar is always replaced: a fresh master gets a fresh secret, and an
# old sidecar holding an old secret would fail every query instead of falling back.
DBD_PORT="${AVALON_DBD_PORT:-9217}"
if [[ -z "${AVALON_DBD_SECRET:-}" ]]; then
    AVALON_DBD_SECRET="$(openssl rand -hex 16)"
    echo "[dev-up] AVALON_DBD_SECRET not set — generated an ephemeral one for this stack"
fi
export AVALON_DBD_SECRET AVALON_DBD_PORT="$DBD_PORT"
if [[ "$PG_OK" == "true" ]]; then
    DBD_STALE=$(ss -tnlp "sport = :$DBD_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    for spid in $DBD_STALE; do
        echo "[dev-up] Replacing stale avalon-dbd on port $DBD_PORT (PID $spid)"
        kill "$spid" 2>/dev/null || true
    done
    python3 "$PROJECT_DIR/tools/db/avalon_dbd.py" --port "$DBD_PORT" \
        --pid-file "$WORK_DIR/dbd.pid" > "$WORK_DIR/dbd.log" 2>&1 &
    DBD_READY=0
    for _ in $(seq 1 30); do
        if grep -qF "listening on" "$WORK_DIR/dbd.log" 2>/dev/null; then DBD_READY=1; break; fi
        sleep 0.1
    done
    if [[ $DBD_READY -eq 1 ]]; then
        echo "[dev-up] avalon-dbd sidecar ready on 127.0.0.1:$DBD_PORT"
    else
        echo "[dev-up] WARNING: avalon-dbd failed to start — servers fall back to subprocess driver"
        tail -5 "$WORK_DIR/dbd.log" 2>/dev/null || true
    fi
else
    echo "[dev-up] Skipping avalon-dbd (no Postgres) — servers fall back to subprocess driver"
fi

# ── Server paths ────────────────────────────────────────────────────
GATEWAY_DIR="$PROJECT_DIR/server/gateway"
MASTER_DIR="$PROJECT_DIR/server/master"
WORLD_DIR="$PROJECT_DIR/server/world"

# ── Trap: clean up on Ctrl-C ────────────────────────────────────────
cleanup() {
    echo ""
    echo "[dev-up] Shutting down all servers..."
    bash "$SCRIPT_DIR/dev-down.sh" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

# ── Kill stale processes on a port ──────────────────────────────────
# Checks both TCP and UDP. Kills the actual listener PID (godot-bin).
kill_stale() {
    local port=$1
    local stale_pids=""

    # Check both TCP and UDP for stale listeners
    local tcp_pids udp_pids
    tcp_pids=$(ss -tnlp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    udp_pids=$(ss -ulnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u || true)
    stale_pids="$tcp_pids $udp_pids"
    stale_pids=$(echo "$stale_pids" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | xargs || true)

    if [[ -n "$stale_pids" ]]; then
        echo "[dev-up] Killing stale godot-bin on port $port: $stale_pids"
        for spid in $stale_pids; do
            kill -9 "$spid" 2>/dev/null || true
        done
        sleep 1
        if ss -tnlp "sport = :$port" 2>/dev/null | grep -q "godot" \
           || ss -ulnp "sport = :$port" 2>/dev/null | grep -q "godot"; then
            echo "[dev-up] FATAL: port $port still occupied after kill"
            exit 1
        fi
    fi
}

# ── Launch a single server ──────────────────────────────────────────
# Args: $1=server_name $2=project_dir $3=port $4=log_keyword
# Returns: 0 on success, 1 on failure
launch_server() {
    local name=$1
    local project_dir=$2
    local port=$3
    local keyword=$4
    local log_file="$WORK_DIR/${name}.log"

    echo "[dev-up] Starting ${name} on port ${port}..."
    kill_stale "$port"

    # Import project resources (--import only compiles GDScript cache, no game logic → no secrets needed)
    $FLATPAK_BASE --headless --path "$project_dir" --import >/dev/null 2>&1

    # Launch via the resolver; --env= penetrates the flatpak sandbox (flatpak mode) or becomes a
    # real child env var (native 4.7 mode). Teardown (dev-down.sh) is port-based, not PID-based.
    "$GODOT_BIN" \
        --env="AVALON_JWT_SECRET=${AVALON_JWT_SECRET:-}" \
        --env="AVALON_JWT_REFRESH_SECRET=${AVALON_JWT_REFRESH_SECRET:-}" \
        --env="AVALON_AUTH_MODE=${AVALON_AUTH_MODE:-accounts}" \
        --env="AVALON_PORT=${WORLD_PORT}" \
        --env="AVALON_PG_PASSWORD=${AVALON_PG_PASSWORD:-}" \
        --env="AVALON_SPAWN_FIXED=${AVALON_SPAWN_FIXED:-}" \
        --env="AVALON_OPS_SECRET=${AVALON_OPS_SECRET:-}" \
        --env="AVALON_OPS_PORT=${AVALON_OPS_PORT:-9215}" \
        --env="AVALON_DBD_SECRET=${AVALON_DBD_SECRET:-}" \
        --env="AVALON_DBD_PORT=${AVALON_DBD_PORT:-9217}" \
        --env="AVALON_DB_DRIVER=${AVALON_DB_DRIVER:-}" \
        --env="AVALON_MIN_BUILD=${AVALON_MIN_BUILD:-}" \
        --filesystem="$PROJECT_DIR" \
        --filesystem=/tmp \
        --headless --path "$project_dir" --scene res://scenes/main.tscn \
        > "$log_file" 2>&1 &

    echo "[dev-up]   ${name} launched"

    # Wait for ready (15-second timeout)
    local ready=0
    for i in $(seq 1 30); do
        sleep 0.5
        if grep -qF "$keyword" "$log_file" 2>/dev/null; then
            ready=1
            break
        fi
    done

    if [[ $ready -eq 1 ]]; then
        echo "[dev-up]   ${name} ready — listening on port ${port}"
        return 0
    else
        echo "[dev-up]   ${name} failed to start within 15 seconds"
        echo "[dev-up]   === ${name} log (last 30 lines) ==="
        tail -30 "$log_file"
        echo "[dev-up]   === end log ==="
        return 1
    fi
}

# ── Launch all servers ──────────────────────────────────────────────
echo ""
echo "===== Avalon Dev Launch ====="
echo "  gateway  ws://0.0.0.0:$GATEWAY_PORT"
echo "  master   ws://0.0.0.0:$MASTER_PORT"
echo "  world    enet://0.0.0.0:$WORLD_PORT"
echo "================================"
echo ""

EXIT_CODE=0
SERVERS_STARTED=0
SERVERS_FAILED=()

# Start master first (gateway and world depend on it)
# Master needs AVALON_JWT_SECRET + Postgres
# T-378: master binds loopback by default now (public bind requires AVALON_RPC_SHARED_SECRET),
# so match the readiness line on any bind address, not the old hardcoded 0.0.0.0.
if launch_server "master" "$MASTER_DIR" "$MASTER_PORT" "listening on ws://" ; then
    ((++SERVERS_STARTED))
else
    SERVERS_FAILED+=("master")
    EXIT_CODE=1
fi

# Start gateway (needs AVALON_JWT_SECRET)
if launch_server "gateway" "$GATEWAY_DIR" "$GATEWAY_PORT" "listening on ws://0.0.0.0:$GATEWAY_PORT"; then
    ((++SERVERS_STARTED))
else
    SERVERS_FAILED+=("gateway")
    EXIT_CODE=1
fi

# Start world (needs master to be reachable)
if launch_server "world" "$WORLD_DIR" "$WORLD_PORT" "listening on enet://0.0.0.0:$WORLD_PORT"; then
    ((++SERVERS_STARTED))
else
    SERVERS_FAILED+=("world")
    EXIT_CODE=1
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "===== Launch Summary ====="
echo "  Servers started: $SERVERS_STARTED / 3"

if [[ ${#SERVERS_FAILED[@]} -gt 0 ]]; then
    echo "  Failed: ${SERVERS_FAILED[*]}"
fi

echo ""
echo "  Logs:       $WORK_DIR/{master,gateway,world}.log"
echo "  Kill:       ./scripts/dev-down.sh"
echo "============================"

if [[ $EXIT_CODE -ne 0 ]]; then
    echo ""
    echo "[dev-up] Some servers failed to start. Check the messages above."
    echo "[dev-up] Common fixes:"
    if [[ "$PG_OK" != "true" ]]; then
        echo "  - Start Postgres: sudo systemctl start postgresql"
    fi
    if [[ -z "${AVALON_JWT_SECRET:-}" ]]; then
        echo "  - Set AVALON_JWT_SECRET (32+ bytes): copy .env.example to .env"
    fi
fi

exit $EXIT_CODE
