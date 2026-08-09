#!/usr/bin/env bash
# test-pg-errors.sh — T-069: pg_query.sh must PROPAGATE SQL errors, and a transactional
# persist script must ROLL BACK atomically (original rows survive a mid-script failure).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
log() { echo "[test-pg-errors] $*"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then set -a; source "$PROJECT_DIR/.env"; set +a; fi
if [[ -z "${AVALON_PG_PASSWORD:-}" ]]; then log "FATAL: AVALON_PG_PASSWORD not set (.env missing?)"; exit 1; fi

PGQ="bash scripts/infra/pg_query.sh"
fails=0

# 1. Good SQL exits 0.
if $PGQ "SELECT 1" >/dev/null 2>&1; then
	log "PASS: good SQL exits 0"
else
	log "FAIL: good SQL exited non-zero"; fails=$((fails+1))
fi

# 2. Bad SQL exits non-zero (was exit 0 before ON_ERROR_STOP — every DB write could
#    silently fail while the game reported success).
if $PGQ "SELEC 1" >/dev/null 2>&1; then
	log "FAIL: syntactically bad SQL exited 0 (errors are being swallowed)"; fails=$((fails+1))
else
	log "PASS: bad SQL exits non-zero"
fi

# 3. Transactional persist rolls back: seed a character + one inventory row, then run a
#    BEGIN; DELETE; <failing INSERT>; COMMIT; script — the DELETE must be rolled back.
CHAR_ID=$($PGQ "INSERT INTO chars.characters (username, class) VALUES ('t069_probe','warrior')
	ON CONFLICT (username) DO UPDATE SET class='warrior' RETURNING id" 2>/dev/null \
	| grep -E '^[0-9]+$' | tail -1)
if [[ -z "$CHAR_ID" ]]; then log "FAIL: could not seed test character"; exit 1; fi
$PGQ "DELETE FROM inventory.character_items WHERE character_id = $CHAR_ID" >/dev/null 2>&1
$PGQ "INSERT INTO inventory.character_items (character_id, slot_type, slot_index, item_id, item_count)
	VALUES ($CHAR_ID, 'bag', 0, 'itm_t069_relic', 1)" >/dev/null 2>&1

if $PGQ "BEGIN;
DELETE FROM inventory.character_items WHERE character_id = $CHAR_ID;
INSERT INTO inventory.character_items (character_id, slot_type, slot_index, item_id, item_count)
	VALUES ($CHAR_ID, 'bag', 1, NULL, 1);
COMMIT;" >/dev/null 2>&1; then
	log "FAIL: mid-transaction failure did not propagate (exit 0)"; fails=$((fails+1))
else
	log "PASS: mid-transaction failure propagated"
fi

SURVIVORS=$($PGQ "SELECT count(*) FROM inventory.character_items
	WHERE character_id = $CHAR_ID AND item_id = 'itm_t069_relic'" 2>/dev/null \
	| grep -E '^[0-9]+$' | tail -1)
if [[ "$SURVIVORS" == "1" ]]; then
	log "PASS: original inventory row survived the rolled-back persist"
else
	log "FAIL: original row lost (count=$SURVIVORS) — persist is not atomic"; fails=$((fails+1))
fi

# Cleanup.
$PGQ "DELETE FROM inventory.character_items WHERE character_id = $CHAR_ID" >/dev/null 2>&1
$PGQ "DELETE FROM chars.characters WHERE username = 't069_probe'" >/dev/null 2>&1

if [[ $fails -gt 0 ]]; then
	log "FAIL — $fails assertion(s) failed"
	exit 1
fi
log "PASS — SQL errors propagate; transactional persist rolls back atomically"
