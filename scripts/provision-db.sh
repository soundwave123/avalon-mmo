#!/usr/bin/env bash
# provision-db.sh — idempotent Postgres bootstrap for Avalon.
#
# Targets the containerized Postgres defined in infra/docker-compose.yml
# (container name: avalon-postgres). Uses `podman exec` to run psql inside
# the container where trust auth applies on loopback connections.
#
# Applies init.sql (schemas + heartbeat tables) and all migrations in order.
#
# Requires: avalon-postgres container is running and healthy.
#           Run `make dev-up` first if it isn't.
#
# Usage:
#   bash scripts/provision-db.sh
#
# Idempotent — safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONTAINER="avalon-postgres"

# ── Pre-flight: container must be running ──────────────────────────────────

if ! podman ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[provision] ERROR: container '$CONTAINER' is not running." >&2
    echo "[provision] Run 'make dev-up' first, then re-run provision." >&2
    exit 1
fi

# ── Helper: run psql inside the container ──────────────────────────────────
# Trust auth works inside the container on loopback. No password needed.
run_psql() {
    podman exec "$CONTAINER" psql -U avalon -d avalon -t -A "$@"
}

run_psql_verbose() {
    podman exec "$CONTAINER" psql -U avalon -d avalon "$@"
}

# ── Apply init.sql ─────────────────────────────────────────────────────────
echo "[provision] Checking init.sql..."

INIT_DONE=$(run_psql -c "
SELECT CASE
    WHEN EXISTS (SELECT FROM pg_namespace WHERE nspname = 'audit')
     AND EXISTS (SELECT FROM audit.heartbeat LIMIT 1)
    THEN 'yes' ELSE 'no' END;
")

if [[ "$INIT_DONE" == "yes" ]]; then
    echo "[provision] init.sql already applied — skipping."
else
    echo "[provision] Applying init.sql..."
    run_psql_verbose -f "$PROJECT_DIR/infra/postgres/init.sql" 2>&1 | sed 's/^/[provision] /'
    echo "[provision] init.sql applied."
fi

# ── Apply migrations ──────────────────────────────────────────────────────
echo "[provision] Applying migrations..."
MIGRATION_DIR="$PROJECT_DIR/infra/postgres/migrations"

if [[ ! -d "$MIGRATION_DIR" ]]; then
    echo "[provision] WARNING: no migrations directory at $MIGRATION_DIR" >&2
else
    migration_count=0
    for migration in $(find "$MIGRATION_DIR" -name '*.sql' -type f | sort); do
        echo "[provision] Applying $(basename "$migration")..."
        # Use -v ON_ERROR_STOP for migrations — each is idempotent with IF NOT EXISTS
        # but if one truly fails, we want to know.
        podman exec -i "$CONTAINER" psql -U avalon -d avalon -v ON_ERROR_STOP=1 -f /dev/stdin \
            < "$migration" 2>&1 | sed 's/^/[provision] /'
        migration_count=$((migration_count + 1))
    done
    echo "[provision] $migration_count migration(s) applied."
fi

# ── Verification ───────────────────────────────────────────────────────────
echo "[provision] Verifying provisioning..."

AUTH_TABLES=$(run_psql -c "
SELECT string_agg(tablename, ', ' ORDER BY tablename)
FROM pg_tables WHERE schemaname = 'auth';
")
echo "[provision] auth schema tables: $AUTH_TABLES"

SCHEMA_COUNT=$(run_psql -c "
SELECT count(*) FROM pg_namespace
WHERE nspname IN ('auth','chars','world','economy','inventory','audit');
")

if [[ "$SCHEMA_COUNT" == "6" ]]; then
    echo "[provision] OK: all 6 schemas present."
else
    echo "[provision] WARNING: expected 6 schemas, found $SCHEMA_COUNT" >&2
fi

echo ""
echo "[provision] Done. Container '$CONTAINER' is provisioned."
echo "[provision] Test: podman exec $CONTAINER psql -U avalon -d avalon -c 'SELECT 1;'"
