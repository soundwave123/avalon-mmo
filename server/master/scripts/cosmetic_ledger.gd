class_name CosmeticLedger
extends RefCounted
# T-476: append-only record of every cosmetic_currency movement the master (the sole authority)
# applies. Mirrors coin_ledger: SERVER-OBSERVED ONLY — record() is called from
# ServicesStore.adjust_cosmetic_currency (mint from the earn hooks = +, store spend = -), never from
# a client verb. One cheap INSERT on the real path, an in-memory list in test mode so the currency
# paths unit-test with no DB. Makes the currency auditable so it can't silently inflate or go dead.

const _CM = preload("res://scripts/character_manager.gd")  # reuse its DB bridge

# Canonical movement reasons — the mint faucets and the single store sink. Constants keep every
# writer/test on the exact spelling (see migration 040).
const REASON_DAILY := "daily_cosmetic"  # faucet: daily appointment claim
const REASON_DISCOVERY := "discovery_cosmetic"  # faucet: exploration
const REASON_VAULT := "vault_cosmetic"  # faucet: weekly vault choice
const REASON_PURCHASE := "cosmetic_purchase"  # sink: store spend

static var _test_skip_db: bool = false
static var _test_rows: Array = []


static func reset_for_test() -> void:
	_test_skip_db = true
	_test_rows.clear()


# Record one movement. delta is signed (+ mint/faucet, - store sink); reason names the source. A
# zero delta or empty reason is dropped so no-ops never pollute it. Best-effort: a failed INSERT
# never blocks the currency move (identical to coin_ledger).
static func record(character_id: int, delta: int, reason: String) -> void:
	if delta == 0 or reason == "":
		return
	if _test_skip_db:
		_test_rows.append({"character_id": character_id, "delta": delta, "reason": reason})
		return
	(
		_CM
		. db_execute(
			"INSERT INTO econ.cosmetic_currency_ledger (character_id, delta, reason) VALUES ($1, $2, $3)",
			[character_id, delta, reason]
		)
	)


static func test_rows() -> Array:  # test accessor
	return _test_rows
