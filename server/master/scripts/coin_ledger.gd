class_name CoinLedger
extends RefCounted
# T-366: append-only record of every coin movement the master (the sole coin authority) applies.
# SERVER-OBSERVED ONLY — record() is called from ServicesStore.adjust_coins / trade_ops persistence,
# never from a client verb (there is no @rpc / dispatch surface into this store). It mirrors
# telemetry_store: one cheap INSERT on the real path, an in-memory list in test mode so the coin
# paths unit-test with no DB. tools/coin_ledger.py aggregates it into net-creation-per-day/band,
# the inflation guard for a faucet-heavy economy.

const _CM = preload("res://scripts/character_manager.gd")  # reuse its DB bridge

# T-430: canonical vendor flow names. These are already classified by the migration-029
# econ.coin_flow view; constants keep every writer/test on the exact registered spelling.
const REASON_VENDOR_SELL := "vendor_sell"  # faucet
const REASON_VENDOR_BUY := "vendor_buy"  # sink
const REASON_TALENT_REROLL := "talent_reroll"  # sink (T-475/T-525: scaling respec cost)
const REASON_MOUNT_TRAINING := "mount_training"  # sink (T-658: one-time learn-to-ride cost)
# T-610: faucet — the one reason NOT written through record()/adjust_coins on the real path: the
# character-INSERT statements (master ensure_character, gateway create_character) ledger it via a
# CTE so grant and character row are atomic. record() is still called in test mode for parity.
const REASON_STARTING_GRANT := "starting_grant"

# T-610: the master's T-507 bootstrap INSERT (fresh account -> slot-0 character named after it),
# owned here because the seed CTE is the ledger's invariant: the starting balance (schema
# DEFAULT, RETURNING coins so the delta is exact) lands in econ.coin_ledger in the same
# statement, atomically. The gateway's create_character carries the same seed CTE for alts.
# T-716: name_chosen=false here (and ONLY here) — the bootstrap name is the ACCOUNT name, picked
# FOR the player, so this is the one character that still owes the in-world name step. Migration
# 053 defaults the column to true, so every other character keeps its name and is never re-asked.
const BOOTSTRAP_CHARACTER_INSERT_SQL := (
	"WITH ins AS (INSERT INTO chars.characters (username, name, slot, name_chosen) "
	+ "SELECT $1, $1, 0, false WHERE NOT EXISTS (SELECT 1 FROM chars.characters "
	+ "WHERE (username = $1 OR name = $1) AND deleted_at IS NULL) "
	+ "ON CONFLICT DO NOTHING RETURNING id, coins) "
	+ "INSERT INTO econ.coin_ledger (character_id, delta, reason) "
	+ "SELECT id, coins, 'starting_grant' FROM ins WHERE coins > 0"
)

static var _test_skip_db: bool = false
static var _test_rows: Array = []


static func reset_for_test() -> void:
	_test_skip_db = true
	_test_rows.clear()


# Record one coin movement. delta is signed copper (+ credit/faucet, - debit/sink); reason names
# the faucet/sink/transfer source (see migration 016). A zero delta or empty reason is dropped so
# accounting no-ops never pollute it. Best-effort: a failed INSERT never blocks the coin move.
static func record(character_id: int, delta: int, reason: String) -> void:
	if delta == 0 or reason == "":
		return
	if _test_skip_db:
		_test_rows.append({"character_id": character_id, "delta": delta, "reason": reason})
		return
	_CM.db_execute(
		"INSERT INTO econ.coin_ledger (character_id, delta, reason) VALUES ($1, $2, $3)",
		[character_id, delta, reason]
	)


static func test_rows() -> Array:  # test accessor
	return _test_rows


# T-610: every character birth now seeds a starting_grant row, so op-level tests asserting "this
# action wrote exactly N rows / nothing" read through this filter to keep asserting THEIR writes.
static func test_move_rows() -> Array:
	return _test_rows.filter(
		func(row: Dictionary) -> bool: return str(row["reason"]) != REASON_STARTING_GRANT
	)
