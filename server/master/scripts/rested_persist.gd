# T-360: Rested-XP persistence + config (extracted from character_manager.gd, which sits AT the
# 1000-line gdlint cap — same reason T-353 split out inventory_persist.gd). This module owns the
# owner-tunable rested config (data/rested.json), the level-scaled cap, the award split, and the two
# lifecycle hooks (accrue-on-login, stamp-on-logout). The PURE math lives in rested_logic.gd; this
# layer loads config and drives Postgres / the test backend. character_manager delegates to it.
#
# Backend seam: character_manager passes its `_test_skip_db` flag, its `_test_characters` dict (a
# reference — mutations persist), and Callables for `_query`/`_execute`, so this module needs no DB
# credentials of its own and stays unit-testable against the in-memory backend.

extends RefCounted

const _RL = preload("res://scripts/rested_logic.gd")
const _LV = preload("res://scripts/leveling.gd")

const _RESTED_PATH := "res://data/rested.json"
const _RESTED_FALLBACK := {
	"accrual_per_hour": 50, "cap_levels_multiplier": 1.5, "bonus_percent": 100
}
static var _cfg: Dictionary = {}
static var _loaded: bool = false


static func _ensure_cfg() -> void:
	if _loaded:
		return
	_loaded = true
	_cfg = _RESTED_FALLBACK.duplicate(true)
	if not FileAccess.file_exists(_RESTED_PATH):
		return
	var file := FileAccess.open(_RESTED_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return
	for key: String in _RESTED_FALLBACK:
		if parsed.has(key):
			_cfg[key] = parsed[key]


# Banked-rest ceiling for a character at (level, xp): cap_levels_multiplier * this level's XP span
# (WoW's 150% of a level). 0 at max level — rested naturally stops.
static func cap(level: int, xp: int) -> int:
	_ensure_cfg()
	var span: int = int(_LV.progress(level, xp).get("xp_for_next_level", 0))
	return int(float(span) * float(_cfg.get("cap_levels_multiplier", 1.5)))


# Split a base award through the rested pool using the configured bonus_percent. Returns
# rested_logic's {base, bonus, total, boosted_base, pool_after}.
static func split(pool: int, base_xp: int) -> Dictionary:
	_ensure_cfg()
	return _RL.split_award(pool, base_xp, int(_cfg.get("bonus_percent", 100)))


# T-358: the award split, gated by use_rested. use_rested=false (quest XP) bypasses the pool
# entirely — the base is granted whole, no bonus, pool untouched (WoW: rested boosts kill XP only).
static func _award_split(pool: int, base_xp: int, use_rested: bool) -> Dictionary:
	if use_rested:
		return split(pool, base_xp)
	return {"base": base_xp, "bonus": 0, "total": base_xp, "boosted_base": 0, "pool_after": pool}


# Grant XP through the rested pool + leveling, then persist (the single XP grant path; T-035 body
# moved here so rested layers in without bloating character_manager past the gdlint cap). The banked
# pool boosts the award and drains 1:1 with the base it boosted; `amount` (base) is never changed so
# the XP faucet the ledger balances stays untouched — rested only accelerates within the curve.
# Returns the leveling result ({level, xp, leveled_up, levels_gained}) plus {rested_bonus,
# rested_remaining}, or {} if the character is unknown.
# T-358: `use_rested` gates the banked-pool boost. WoW rule — rested applies to MOB-KILL XP only;
# quest turn-in XP passes use_rested=false so it never touches the pool (bonus 0, pool untouched).
static func apply_award(
	character_id: int,
	amount: int,
	use_rested: bool,
	skip_db: bool,
	test_chars: Dictionary,
	query_cb: Callable,
	execute_cb: Callable
) -> Dictionary:
	if skip_db:
		var row := _test_row(test_chars, character_id)
		if row.is_empty():
			return {}
		var s := _award_split(int(row.get("rested_pool", 0)), amount, use_rested)
		var r := _LV.apply_xp(int(row["level"]), int(row["xp"]), int(s["total"]))
		row["level"] = r["level"]
		row["xp"] = r["xp"]
		row["rested_pool"] = int(s["pool_after"])
		r["rested_bonus"] = int(s["bonus"])
		r["rested_remaining"] = int(s["pool_after"])
		return r

	var rows: Array = query_cb.call(
		"SELECT level, xp, rested_pool FROM chars.characters WHERE id = $1", [character_id]
	)
	if rows.is_empty():
		return {}
	var s := _award_split(int(rows[0].get("rested_pool", 0)), amount, use_rested)
	var r := _LV.apply_xp(int(rows[0]["level"]), int(rows[0]["xp"]), int(s["total"]))
	execute_cb.call(
		"UPDATE chars.characters SET xp = $1, level = $2, rested_pool = $3 WHERE id = $4",
		[r["xp"], r["level"], int(s["pool_after"]), character_id]
	)
	r["rested_bonus"] = int(s["bonus"])
	r["rested_remaining"] = int(s["pool_after"])
	return r


# Find the test-backend character dict by id (or {} — mutate in place, it is a reference).
static func _test_row(test_chars: Dictionary, character_id: int) -> Dictionary:
	for username: String in test_chars:
		var character: Dictionary = test_chars[username]
		if int(character.get("id", -1)) == character_id:
			return character
	return {}


# Login hook: bank rested for the offline window (now - rested_logout_at) at the configured rate,
# clamped to the level-scaled cap, then reset the window (logout_at = 0 = online). Returns new pool.
static func accrue_on_login(
	character_id: int,
	now_unix: int,
	skip_db: bool,
	test_chars: Dictionary,
	query_cb: Callable,
	execute_cb: Callable
) -> int:
	_ensure_cfg()
	var rate: int = int(_cfg.get("accrual_per_hour", 50))
	if skip_db:
		var row := _test_row(test_chars, character_id)
		if row.is_empty():
			return 0
		var pool := _accrued(row, now_unix, rate)
		row["rested_pool"] = pool
		row["rested_logout_at"] = 0
		return pool

	var rows: Array = query_cb.call(
		"SELECT level, xp, rested_pool, rested_logout_at FROM chars.characters WHERE id = $1",
		[character_id]
	)
	if rows.is_empty():
		return 0
	var pool := _accrued(rows[0], now_unix, rate)
	execute_cb.call(
		"UPDATE chars.characters SET rested_pool = $1, rested_logout_at = 0 WHERE id = $2",
		[pool, character_id]
	)
	return pool


# Shared accrual math for one row ({level, xp, rested_pool, rested_logout_at}).
static func _accrued(row: Dictionary, now_unix: int, rate: int) -> int:
	var logout_at: int = int(row.get("rested_logout_at", 0))
	var elapsed: int = (now_unix - logout_at) if logout_at > 0 else 0
	var ceiling: int = cap(int(row.get("level", 1)), int(row.get("xp", 0)))
	return _RL.accrue(int(row.get("rested_pool", 0)), elapsed, rate, ceiling)


# Logout hook: stamp the start of the offline accrual window.
static func mark_logout(
	character_id: int, now_unix: int, skip_db: bool, test_chars: Dictionary, execute_cb: Callable
) -> void:
	if skip_db:
		var row := _test_row(test_chars, character_id)
		if not row.is_empty():
			row["rested_logout_at"] = now_unix
		return
	execute_cb.call(
		"UPDATE chars.characters SET rested_logout_at = $1 WHERE id = $2", [now_unix, character_id]
	)


# T-414: comfort-food grant — a consumable's "rested" effect banks pool directly, clamped to the
# SAME level-scaled cap the offline accrual respects (anti-abuse: eating past the cap wastes the
# excess; rested still only accelerates within the XP curve). Returns the new pool.
static func grant_pool(
	character_id: int,
	amount: int,
	skip_db: bool,
	test_chars: Dictionary,
	query_cb: Callable,
	execute_cb: Callable
) -> int:
	var add: int = maxi(0, amount)
	if skip_db:
		var row := _test_row(test_chars, character_id)
		if row.is_empty():
			return 0
		var ceiling := cap(int(row.get("level", 1)), int(row.get("xp", 0)))
		row["rested_pool"] = mini(ceiling, int(row.get("rested_pool", 0)) + add)
		return int(row["rested_pool"])
	var rows: Array = query_cb.call(
		"SELECT level, xp, rested_pool FROM chars.characters WHERE id = $1", [character_id]
	)
	if rows.is_empty():
		return 0
	var ceiling := cap(int(rows[0].get("level", 1)), int(rows[0].get("xp", 0)))
	var pool: int = mini(ceiling, int(rows[0].get("rested_pool", 0)) + add)
	execute_cb.call(
		"UPDATE chars.characters SET rested_pool = $1 WHERE id = $2", [pool, character_id]
	)
	return pool


# Read-only: the character's current banked rested pool (for the XP-bar payload).
static func remaining(
	character_id: int, skip_db: bool, test_chars: Dictionary, query_cb: Callable
) -> int:
	if skip_db:
		return int(_test_row(test_chars, character_id).get("rested_pool", 0))
	var rows: Array = query_cb.call(
		"SELECT rested_pool FROM chars.characters WHERE id = $1", [character_id]
	)
	return int(rows[0].get("rested_pool", 0)) if not rows.is_empty() else 0
