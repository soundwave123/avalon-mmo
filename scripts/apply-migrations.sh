#!/usr/bin/env bash
# apply-migrations.sh — T-398: state-tracked Postgres migration runner for Avalon.
#
# The dev DB silently fell 9 migrations behind the code (schema at 010; 011–018 never
# applied) because applying migrations was a by-hand step no one ran and old migrations
# (001–010) are NOT idempotent — you cannot just re-run the whole set. This runner tracks
# what has been applied in `infra.schema_migrations` and only applies the missing files.
#
# Usage:
#   apply-migrations.sh            apply every pending migration, in filename order
#   apply-migrations.sh --check    print MIGRATIONS: OK|BEHIND (drift gate; exit 0 if OK)
#   apply-migrations.sh --selftest run the runner against a throwaway schema + temp files
#
# Discipline mirrors scripts/infra/pg_query.sh:
#   - psql on the host with -v ON_ERROR_STOP=1 (a SQL error must abort, never exit 0)
#   - connection from env: PG_HOST / PG_PORT / PG_USER / AVALON_PG_PASSWORD (same defaults)
# Hard-stops on the FIRST failing migration and prints its filename, so dev-up never
# launches servers against a half-migrated schema.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "[apply-migrations] $*"; }

# ── Load .env for standalone runs (dev-up already sources it; harmless to re-source) ──
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
fi

# ── Connection (identical defaults to pg_query.sh) ───────────────────────────────────
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-avalon}"
DATABASE="${AVALON_PG_DATABASE:-avalon}"

# Overridable so --selftest can run against a THROWAWAY schema + temp migration dir
# without touching the real bookkeeping table or the shipped migrations.
MIG_SCHEMA="${AVALON_MIGRATIONS_SCHEMA:-infra}"
MIGRATION_DIR="${AVALON_MIGRATIONS_DIR:-$PROJECT_DIR/infra/postgres/migrations}"

if [[ -z "${AVALON_PG_PASSWORD:-}" ]]; then
    log "FATAL: AVALON_PG_PASSWORD not set (.env missing?)"
    exit 1
fi

PSQL_BASE=(-h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE" -v ON_ERROR_STOP=1)

# ── psql helpers ─────────────────────────────────────────────────────────────────────
# psql_scalar SQL  → prints a single value (trimmed, no header/footer). Exits non-zero on error.
psql_scalar() {
    PGPASSWORD="$AVALON_PG_PASSWORD" psql "${PSQL_BASE[@]}" -tA -c "$1"
}
# psql_exec SQL [-v k=v...]  → run a statement, no output capture.
psql_exec() {
    local sql="$1"; shift
    PGPASSWORD="$AVALON_PG_PASSWORD" psql "${PSQL_BASE[@]}" -q "$@" -c "$sql"
}
# psql_apply_file FILE → apply a migration in a single transaction (partial failure rolls
# back). ON_ERROR_STOP makes psql exit 3 on the first SQL error.
psql_apply_file() {
    PGPASSWORD="$AVALON_PG_PASSWORD" psql "${PSQL_BASE[@]}" -q --single-transaction -f "$1"
}

# ── Sentinel probe map (baseline backfill only) ──────────────────────────────────────
# Maps each shipped migration → a boolean SQL that is TRUE iff that migration already ran.
# Choice per migration (an object the file is the FIRST to create):
#   tables  → to_regclass('schema.table') IS NOT NULL
#   columns → an information_schema.columns EXISTS probe (for pure ADD COLUMN migrations)
# Every migration 001–020 creates a clearly-owned object, so none has to borrow an earlier
# sentinel; if a future ADD-only migration lacks one, point it at the nearest earlier file's
# sentinel and note it here.
declare -A PROBES
_col_probe() { # schema table column → EXISTS boolean SQL
    echo "EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='$1' AND table_name='$2' AND column_name='$3')"
}
_tbl_probe() { echo "to_regclass('$1') IS NOT NULL"; } # 'schema.table'

load_real_probes() {
    PROBES=()
    PROBES[001_add_sessions.sql]="$(_tbl_probe auth.sessions)"
    PROBES[002_add_refresh_tokens.sql]="$(_col_probe auth sessions refresh_token_id)"
    PROBES[003_add_session_tokens.sql]="$(_tbl_probe auth.session_tokens)"
    PROBES[004_add_m2_tables.sql]="$(_tbl_probe chars.characters)"
    PROBES[005_add_quest_objectives.sql]="$(_tbl_probe chars.character_quest_objectives)"
    PROBES[006_add_character_talents.sql]="$(_tbl_probe chars.character_talents)"
    PROBES[007_add_class_locked.sql]="$(_col_probe chars characters class_locked)"
    PROBES[008_add_m5_services.sql]="$(_tbl_probe market.auctions)"
    PROBES[009_add_telemetry.sql]="$(_tbl_probe telemetry.gameplay_events)"
    PROBES[010_add_dungeon_blue_claims.sql]="$(_tbl_probe chars.dungeon_blue_claims)"
    PROBES[011_add_era_carry.sql]="$(_col_probe inventory character_items era_scaled_to)"
    PROBES[012_add_rested_xp.sql]="$(_col_probe chars characters rested_pool)"
    PROBES[013_add_social.sql]="$(_tbl_probe chars.character_social)"
    PROBES[014_add_guilds.sql]="$(_tbl_probe chars.guilds)"
    PROBES[015_add_achievements.sql]="$(_tbl_probe chars.character_achievement)"
    PROBES[016_add_coin_ledger.sql]="$(_tbl_probe econ.coin_ledger)"
    PROBES[017_add_pvp_ratings.sql]="$(_tbl_probe pvp.ratings)"
    PROBES[018_add_cosmetics.sql]="$(_col_probe inventory character_items appearance_override)"
    PROBES[019_add_item_durability.sql]="$(_tbl_probe inventory.item_durability)"
    PROBES[020_add_pvp_honor.sql]="$(_tbl_probe pvp.honor)"
}

# ── Core primitives (operate on MIG_SCHEMA / MIGRATION_DIR / PROBES globals) ──────────

# Returns 0 (true) if the bookkeeping table already existed before this run.
bookkeeping_exists() {
    local present
    present="$(psql_scalar "SELECT to_regclass('${MIG_SCHEMA}.schema_migrations') IS NOT NULL;")"
    [[ "$present" == "t" ]]
}

ensure_bookkeeping() {
    psql_exec "CREATE SCHEMA IF NOT EXISTS ${MIG_SCHEMA};
CREATE TABLE IF NOT EXISTS ${MIG_SCHEMA}.schema_migrations (
    filename   TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);"
}

# Record a filename as applied (idempotent). NOTE: psql -c does NOT expand :'var' psql
# variables (the pg_query.sh -f lesson) — the filename is inlined with quote-doubling
# instead. Filenames here are repo-controlled ([0-9a-z_.]), the escaping is belt+braces.
record_migration() {
    local fn="${1//\'/\'\'}"
    psql_exec "INSERT INTO ${MIG_SCHEMA}.schema_migrations (filename) VALUES ('$fn')
               ON CONFLICT (filename) DO NOTHING;"
}

is_recorded() {
    local present
    present="$(psql_scalar "SELECT EXISTS(SELECT 1 FROM ${MIG_SCHEMA}.schema_migrations WHERE filename = '$1');")"
    [[ "$present" == "t" ]]
}

# List migration files (basenames), filename-sorted.
migration_files() {
    find "$MIGRATION_DIR" -maxdepth 1 -name '*.sql' -type f -printf '%f\n' 2>/dev/null | sort
}

# One-time baseline backfill: for each migration whose sentinel object ALREADY exists,
# record it WITHOUT running the file. Safe on a fresh DB (records nothing) and on the
# current dev DB (records 001–020). Only called when the bookkeeping table was just created.
baseline_backfill() {
    local fn probe present count=0
    for fn in $(migration_files); do
        probe="${PROBES[$fn]:-}"
        [[ -n "$probe" ]] || continue
        present="$(psql_scalar "SELECT ($probe);")"
        if [[ "$present" == "t" ]]; then
            record_migration "$fn"
            count=$((count + 1))
        fi
    done
    log "baseline: marked $count pre-existing migration(s) without re-applying"
}

# Apply every pending migration in order. Hard-stop on the first failure with its filename.
apply_pending() {
    local fn applied=0 skipped=0
    for fn in $(migration_files); do
        if is_recorded "$fn"; then
            skipped=$((skipped + 1))
            continue
        fi
        log "applying $fn ..."
        if ! psql_apply_file "$MIGRATION_DIR/$fn"; then
            log "FATAL: migration FAILED: $fn (schema left unchanged for this file; aborting)"
            return 1
        fi
        record_migration "$fn"
        applied=$((applied + 1))
    done
    log "done: $applied applied, $skipped already up-to-date"
}

# ── Drift check (--check / gate7) ────────────────────────────────────────────────────
run_check() {
    local highest_file highest_row
    highest_file="$(migration_files | tail -1)"
    if ! bookkeeping_exists; then
        echo "MIGRATIONS: BEHIND (no ${MIG_SCHEMA}.schema_migrations table — never migrated)"
        return 1
    fi
    highest_row="$(psql_scalar "SELECT COALESCE(max(filename), '') FROM ${MIG_SCHEMA}.schema_migrations;")"
    if [[ "$highest_file" == "$highest_row" ]]; then
        echo "MIGRATIONS: OK ($highest_row)"
        return 0
    fi
    echo "MIGRATIONS: BEHIND (highest file=$highest_file, highest recorded=${highest_row:-none})"
    return 1
}

# ── Normal run ───────────────────────────────────────────────────────────────────────
run_apply() {
    local first_run=false
    if ! bookkeeping_exists; then
        first_run=true
    fi
    ensure_bookkeeping
    if [[ "$first_run" == true ]]; then
        # Selftest pre-populates PROBES with its throwaway sentinels — loading the real map
        # here would clobber them (found live: the psql stub masked exactly this).
        # ${PROBES[*]+x} expands only when the array has elements — bash 5.3 set -u errors
        # on ${#PROBES[@]} for an element-less assoc array, so length can't be tested directly.
        if [[ -z "${PROBES[*]+x}" ]]; then
            load_real_probes
        fi
        baseline_backfill
    fi
    apply_pending
}

# ── Self-test (throwaway schema + temp migration dir; cleans up) ──────────────────────
run_selftest() {
    local ok=0 fail=0
    local ts schema tmpdir
    ts="$(date +%s)_$$"
    schema="infra_selftest_${ts}"
    local probe_schema="selftest_${ts}"
    tmpdir="$(mktemp -d /tmp/apply-migrations-selftest.XXXXXX)"

    _t_pass() { echo "[selftest] PASS: $1"; ok=$((ok + 1)); }
    _t_fail() { echo "[selftest] FAIL: $1"; fail=$((fail + 1)); }

    cleanup_selftest() {
        psql_exec "DROP SCHEMA IF EXISTS ${schema} CASCADE; DROP SCHEMA IF EXISTS ${probe_schema} CASCADE;" >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
    }
    trap cleanup_selftest EXIT

    # Point the runner at the throwaway bookkeeping schema + temp migrations.
    MIG_SCHEMA="$schema"
    MIGRATION_DIR="$tmpdir"

    # Two good migrations that create objects in the probe schema, plus a probe map so the
    # baseline path is exercised too.
    cat > "$tmpdir/001_alpha.sql" <<SQL
CREATE SCHEMA IF NOT EXISTS ${probe_schema};
CREATE TABLE ${probe_schema}.alpha (id INT PRIMARY KEY);
SQL
    cat > "$tmpdir/002_beta.sql" <<SQL
CREATE TABLE ${probe_schema}.beta (id INT PRIMARY KEY);
SQL

    # Case A: fresh — pre-create alpha so baseline records 001 (no re-run), 002 applies.
    psql_exec "CREATE SCHEMA IF NOT EXISTS ${probe_schema}; CREATE TABLE ${probe_schema}.alpha (id INT PRIMARY KEY);"
    PROBES=()
    PROBES[001_alpha.sql]="$(_tbl_probe ${probe_schema}.alpha)"
    PROBES[002_beta.sql]="$(_tbl_probe ${probe_schema}.beta)"

    if run_apply >/dev/null 2>&1; then _t_pass "first run (baseline + apply) exits 0"; else _t_fail "first run exited non-zero"; fi
    if is_recorded "001_alpha.sql"; then _t_pass "001 recorded via baseline"; else _t_fail "001 not recorded"; fi
    if is_recorded "002_beta.sql"; then _t_pass "002 recorded via apply"; else _t_fail "002 not recorded"; fi
    # 001 was baselined (never run): if it had run, CREATE TABLE alpha (no IF NOT EXISTS) would have errored.
    if [[ "$(psql_scalar "SELECT to_regclass('${probe_schema}.beta') IS NOT NULL;")" == "t" ]]; then
        _t_pass "002 actually created beta"; else _t_fail "beta missing after apply"; fi

    # Case B: re-run is a clean no-op (idempotent tracking).
    if run_apply >/dev/null 2>&1; then _t_pass "re-run is a no-op"; else _t_fail "re-run exited non-zero"; fi

    # Case C: drift check OK when caught up. (Capture first: run_check's exit code is
    # meaningful — OK=0, BEHIND=1 — and pipefail would otherwise leak it into the `if`.)
    local chk
    chk="$(run_check 2>&1 || true)"
    if echo "$chk" | grep -q '^MIGRATIONS: OK'; then _t_pass "--check reports OK when current"; else _t_fail "--check not OK when current"; fi

    # Case D: a broken migration aborts with its filename, and is NOT recorded.
    cat > "$tmpdir/003_broken.sql" <<SQL
CREATE TABLE ${probe_schema}.gamma (id INT PRIMARY KEY);
THIS IS NOT SQL;
SQL
    local out
    out="$(run_apply 2>&1 || true)"
    if echo "$out" | grep -q '003_broken.sql'; then _t_pass "broken migration names the file"; else _t_fail "broken migration did not name the file"; fi
    if is_recorded "003_broken.sql"; then _t_fail "broken migration was recorded"; else _t_pass "broken migration NOT recorded"; fi
    # --single-transaction rollback: gamma must not survive the failed migration.
    if [[ "$(psql_scalar "SELECT to_regclass('${probe_schema}.gamma') IS NOT NULL;")" == "f" ]]; then
        _t_pass "failed migration rolled back (gamma absent)"; else _t_fail "gamma leaked from failed migration"; fi

    # Case E: drift check BEHIND while 003 is pending.
    chk="$(run_check 2>&1 || true)"
    if echo "$chk" | grep -q '^MIGRATIONS: BEHIND'; then _t_pass "--check reports BEHIND when pending"; else _t_fail "--check not BEHIND when pending"; fi

    cleanup_selftest
    trap - EXIT
    echo "[selftest] $ok passed, $fail failed"
    [[ "$fail" -eq 0 ]]
}

# ── Dispatch ─────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --check)    run_check ;;
    --selftest) run_selftest ;;
    ""|--apply) run_apply ;;
    *)
        echo "usage: $0 [--apply|--check|--selftest]" >&2
        exit 2
        ;;
esac
