class_name ServicesStore
extends RefCounted

const _CM := preload("res://scripts/character_manager.gd")
const _CL := preload("res://scripts/coin_ledger.gd")  # T-366: coin sink/faucet ledger
const _CCL := preload("res://scripts/cosmetic_ledger.gd")  # T-476: cosmetic_currency ledger
const _DUR := preload("res://scripts/durability.gd")  # T-364: death penalty + repair sink
const _IP := preload("res://scripts/inventory_persist.gd")  # T-430: atomic vendor item+coin commit

# T-208: persistence for the Highkeep services — coins (single copper currency),
# trained-ability unlocks, and the auction table. Split from character_manager (file-size
# budget); same DB + same test-mode discipline (CharacterManager.reset_for_test() chains
# into reset_for_test() here, so existing test setup keeps working unchanged).

static var _test_skip_db: bool = false
static var _test_coins: Dictionary = {}  # character_id -> copper
static var _test_abilities: Dictionary = {}  # character_id -> Array[int]
static var _test_auctions: Array = []  # rows mirroring market.auctions
static var _test_auction_seq: int = 0
static var _test_durability: Dictionary = {}  # character_id -> {slot_key -> {current, max}} (T-364)
static var _test_vault_tier: Dictionary = {}  # character_id -> vault tier int (T-412)
static var _test_recipes: Dictionary = {}  # character_id -> Array[String] recipe ids (T-414)
static var _test_bar_layout: Dictionary = {}  # character_id -> Array[int] slot order (T-422c)
static var _test_rerolls: Dictionary = {}  # character_id -> talent reroll count (T-475/T-525)
static var _test_cosmetic_currency: Dictionary = {}  # character_id -> cosmetic_currency (T-476)


static func reset_for_test() -> void:
	_test_skip_db = true
	_test_coins.clear()
	_test_cosmetic_currency.clear()  # T-476
	_CCL.reset_for_test()  # T-476: keep the cosmetic-currency ledger in-memory for the store tests
	_test_abilities.clear()
	_test_auctions.clear()
	_test_auction_seq = 0
	_test_durability.clear()  # T-364
	_test_vault_tier.clear()  # T-412
	_test_recipes.clear()  # T-414
	_test_bar_layout.clear()  # T-422c
	_test_rerolls.clear()  # T-475/T-525
	_CL.reset_for_test()  # T-366: keep the coin ledger in-memory for coin-path tests


# ---- coins -------------------------------------------------------------------


static func get_coins(character_id: int) -> int:
	if _test_skip_db:
		return int(_test_coins.get(character_id, 100))
	var rows := _query("SELECT coins FROM chars.characters WHERE id = $1", [character_id])
	return int(rows[0].get("coins", 0)) if rows.size() > 0 else 0


static func adjust_coins(character_id: int, delta: int, reason: String = "") -> bool:
	# Never drives a balance negative — callers validate, this enforces. T-366: pass a `reason`
	# (quest_reward | trainer | guild_create | trade | auction_* | ...) to record the move in the
	# coin ledger; the empty default keeps pure balance-only test helpers out of the ledger.
	var now := get_coins(character_id)
	if now + delta < 0:
		return false
	var ok: bool
	if _test_skip_db:
		_test_coins[character_id] = now + delta
		ok = true
	else:
		ok = _execute(
			"UPDATE chars.characters SET coins = coins + $2 WHERE id = $1 AND coins + $2 >= 0",
			[character_id, delta]
		)
	if ok:
		_CL.record(character_id, delta, reason)
	return ok


# T-430: persist one character's complete inventory, coin delta, and ledger row in ONE transaction.
# Vendor buy/sell is the first single-character flow that changes both item rows and currency; using
# adjust_coins + _persist_inventory separately would permit a crash between the two writes. The test
# backend is a single writer with no failure point after validation, while live Postgres rolls every
# statement back if its balance CHECK, inventory insert, or ledger insert fails.
static func commit_inventory_coins(
	character_id: int, slots: Array, delta: int, reason: String, appearance_unlocks: Array = []
) -> bool:
	if reason == "" or delta == 0 or get_coins(character_id) + delta < 0:
		return false
	if _test_skip_db:
		_CM._persist_inventory(character_id, slots, appearance_unlocks)
		return adjust_coins(character_id, delta, reason)

	var stmts: Array = ["BEGIN;"]
	var params: Array = []
	_IP.append_persist(character_id, slots, stmts, params, appearance_unlocks)
	params.append_array([character_id, delta])
	stmts.append(
		(
			"UPDATE chars.characters SET coins = coins + $%d WHERE id = $%d;"
			% [params.size(), params.size() - 1]
		)
	)
	params.append_array([character_id, delta, reason])
	stmts.append(
		(
			(
				"INSERT INTO econ.coin_ledger (character_id, delta, reason) "
				+ "VALUES ($%d,$%d,$%d);"
			)
			% [params.size() - 2, params.size() - 1, params.size()]
		)
	)
	stmts.append("COMMIT;")
	return _CM.db_execute("\n".join(stmts), params)


# ---- cosmetic currency (T-476: earned, persisted store currency) ----------------
# Backs the phantom `cosmetic_currency` reward key with a real balance. Minted by the power-neutral
# earn hooks (daily/streak/discovery/vault), spent in the cosmetic store. Server-authoritative and
# never driven negative — the store pre-validates the balance, this enforces (mirrors adjust_coins).
# Every move rides the append-only cosmetic_currency ledger so it can't inflate or go dead.


static func get_cosmetic_currency(character_id: int) -> int:
	if _test_skip_db:
		return int(_test_cosmetic_currency.get(character_id, 0))
	var rows := _query(
		"SELECT cosmetic_currency FROM chars.characters WHERE id = $1", [character_id]
	)
	return int(rows[0].get("cosmetic_currency", 0)) if rows.size() > 0 else 0


static func adjust_cosmetic_currency(character_id: int, delta: int, reason: String) -> bool:
	var now := get_cosmetic_currency(character_id)
	if now + delta < 0:
		return false
	var ok: bool
	if _test_skip_db:
		_test_cosmetic_currency[character_id] = now + delta
		ok = true
	else:
		ok = _execute(
			(
				"UPDATE chars.characters SET cosmetic_currency = cosmetic_currency + $2 "
				+ "WHERE id = $1 AND cosmetic_currency + $2 >= 0"
			),
			[character_id, delta]
		)
	if ok:
		_CCL.record(character_id, delta, reason)
	return ok


# ---- talent reroll (T-475/T-525: scaling respec coin sink) ----------------------


static func get_talent_rerolls(character_id: int) -> int:
	if _test_skip_db:
		return int(_test_rerolls.get(character_id, 0))
	var rows := _query("SELECT talent_rerolls FROM chars.characters WHERE id = $1", [character_id])
	return int(rows[0].get("talent_rerolls", 0)) if rows.size() > 0 else 0


# Debit `cost`, clear every spent talent, and bump the reroll counter — ATOMICALLY. The debit
# and the clear must never split (a crash between them would be a paid-but-kept or free-and-
# cleared build), so live Postgres runs one BEGIN..COMMIT (the coins CHECK rolls the whole
# reroll back on overdraft) and the ledger row rides the same transaction. Callers still
# pre-validate the balance so a poor purse is a clean rejection, not a rollback.
static func commit_talent_reroll(character_id: int, cost: int) -> bool:
	if cost < 0 or get_coins(character_id) < cost:
		return false
	if _test_skip_db:
		if cost > 0 and not adjust_coins(character_id, -cost, _CL.REASON_TALENT_REROLL):
			return false
		_CM.clear_talents(character_id)
		_test_rerolls[character_id] = int(_test_rerolls.get(character_id, 0)) + 1
		return true
	# Placeholders are unique + sequential with duplicated params, matching the proven
	# commit_inventory_coins multi-statement contract of the DB bridge.
	var stmts: Array = [
		"BEGIN;",
		(
			"UPDATE chars.characters SET coins = coins - $2, "
			+ "talent_rerolls = talent_rerolls + 1 WHERE id = $1;"
		),
		"DELETE FROM chars.character_talents WHERE character_id = $3;",
		"INSERT INTO econ.coin_ledger (character_id, delta, reason) VALUES ($4, $5, $6);",
		"COMMIT;",
	]
	return _CM.db_execute(
		"\n".join(stmts),
		[character_id, cost, character_id, character_id, -cost, _CL.REASON_TALENT_REROLL]
	)


# ---- vault capacity tier (T-412: bank tier ladder coin sink) --------------------


static func get_vault_tier(character_id: int) -> int:
	if _test_skip_db:
		return int(_test_vault_tier.get(character_id, 0))
	var rows := _query("SELECT vault_tier FROM chars.characters WHERE id = $1", [character_id])
	return int(rows[0].get("vault_tier", 0)) if rows.size() > 0 else 0


static func set_vault_tier(character_id: int, tier: int) -> bool:
	if _test_skip_db:
		_test_vault_tier[character_id] = tier
		return true
	return _execute(
		"UPDATE chars.characters SET vault_tier = $2 WHERE id = $1", [character_id, tier]
	)


# ---- trained-ability unlocks ---------------------------------------------------


static func get_unlocked_abilities(character_id: int) -> Array:
	if _test_skip_db:
		return _test_abilities.get(character_id, [])
	var out: Array = []
	var rows := _query(
		"SELECT ability_id FROM chars.character_abilities WHERE character_id = $1", [character_id]
	)
	for row in rows:
		out.append(int(row.get("ability_id", 0)))
	return out


static func grant_ability(character_id: int, ability_id: int) -> bool:
	if _test_skip_db:
		var owned: Array = _test_abilities.get(character_id, [])
		if not (ability_id in owned):
			owned.append(ability_id)
		_test_abilities[character_id] = owned
		return true
	return _execute(
		(
			"INSERT INTO chars.character_abilities (character_id, ability_id) "
			+ "VALUES ($1, $2) ON CONFLICT DO NOTHING"
		),
		[character_id, str(ability_id)]
	)


# ---- known crafting recipes (T-414: trainer-taught, string ids, migration 023) --
# Parallel to the ability unlock store — recipe ids are strings (world content), so they don't fit
# the int character_abilities machinery; same grant-once + read-set shape.


static func get_known_recipes(character_id: int) -> Array:
	if _test_skip_db:
		return _test_recipes.get(character_id, [])
	var out: Array = []
	var rows := _query(
		"SELECT recipe_id FROM chars.character_recipes WHERE character_id = $1", [character_id]
	)
	for row in rows:
		out.append(str(row.get("recipe_id", "")))
	return out


static func grant_recipe(character_id: int, recipe_id: String) -> bool:
	if _test_skip_db:
		var known: Array = _test_recipes.get(character_id, [])
		if not (recipe_id in known):
			known.append(recipe_id)
		_test_recipes[character_id] = known
		return true
	return _execute(
		(
			"INSERT INTO chars.character_recipes (character_id, recipe_id) "
			+ "VALUES ($1, $2) ON CONFLICT DO NOTHING"
		),
		[character_id, recipe_id]
	)


# ---- action-bar layout (T-422c: per-character ability-slot order, migration 026) --
# An ordered Array[int] of ability ids. The WORLD validates it's a permutation of the character's
# known kit before persisting (BarLayoutOps.sanitize); master only stores/loads the order. JSONB
# column, so the read decodes either a live Array (test/native) or a JSON string (pg driver).


static func get_bar_layout(character_id: int) -> Array:
	if _test_skip_db:
		return _test_bar_layout.get(character_id, [])
	var rows := _query("SELECT bar_layout FROM chars.characters WHERE id = $1", [character_id])
	if rows.is_empty():
		return []
	return _decode_layout(rows[0].get("bar_layout", null))


static func save_bar_layout(character_id: int, layout: Array) -> bool:
	var ids: Array = []
	for v in layout:
		ids.append(int(v))  # JSON floats -> ints; the world already validated the id set
	if _test_skip_db:
		_test_bar_layout[character_id] = ids
		return true
	return _execute(
		"UPDATE chars.characters SET bar_layout = $2::jsonb WHERE id = $1",
		[character_id, JSON.stringify(ids)]
	)


# Username → character → persist. Master does NOT re-derive the known-ability set (the ability
# registry lives world-side); it stores the ids the world already permutation-checked. Fail-closed.
static func save_layout_for_user(username: String, layout: Array) -> Dictionary:
	var character: Dictionary = _CM.get_character(username)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	return {"ok": save_bar_layout(int(character.get("id", -1)), layout)}


static func _decode_layout(raw) -> Array:
	var out: Array = []
	var arr = raw
	if not (arr is Array):
		if raw == null or str(raw) == "":
			return out
		arr = JSON.parse_string(str(raw))
	if arr is Array:
		for v in arr:
			out.append(int(v))
	return out


# ---- auction persistence -------------------------------------------------------


static func auction_insert(
	seller_id: int, item_id: String, item_count: int, min_bid: int, buyout: int, duration_s: int
) -> int:
	if _test_skip_db:
		_test_auction_seq += 1
		(
			_test_auctions
			. append(
				{
					"id": _test_auction_seq,
					"seller_id": seller_id,
					"item_id": item_id,
					"item_count": item_count,
					"min_bid": min_bid,
					"buyout": buyout,
					"high_bid": 0,
					"high_bidder_id": 0,
					"expires_at_unix": Time.get_unix_time_from_system() + duration_s,
					"state": "live",
				}
			)
		)
		return _test_auction_seq
	var rows := _query(
		(
			"INSERT INTO market.auctions "
			+ "(seller_id, item_id, item_count, min_bid, buyout, expires_at) VALUES "
			+ "($1,$2,$3,$4,NULLIF($5,0), now() + ($6 || ' seconds')::interval) RETURNING id"
		),
		[seller_id, item_id, item_count, min_bid, buyout, str(duration_s)]
	)
	return int(rows[0].get("id", 0)) if rows.size() > 0 else 0


static func _auction_select(where: String) -> Array:
	return _query(
		(
			(
				"SELECT id, seller_id, item_id, item_count, min_bid, "
				+ "COALESCE(buyout,0) AS buyout, COALESCE(high_bid,0) AS high_bid, "
				+ "COALESCE(high_bidder_id,0) AS high_bidder_id, "
				+ "EXTRACT(EPOCH FROM expires_at)::bigint AS expires_at_unix, state "
				+ "FROM market.auctions %s ORDER BY id"
			)
			% where
		),
		[]
	)


static func auction_rows(live_only: bool = true) -> Array:
	if _test_skip_db:
		var out: Array = []
		for a in _test_auctions:
			if not live_only or str(a["state"]) == "live":
				out.append(a)
		return out
	return _auction_select("WHERE state = 'live'" if live_only else "")


# T-609: lots whose settlement grant (item and/or coin) failed last sweep (bag full at the
# destination) and were left OPEN instead of closed, so the next sweep retries them instead of
# silently eating the item/coins. Deliberately excluded from auction_rows(true) — a pending lot is
# no longer biddable/listable, it is just waiting for delivery to succeed.
static func auction_pending_rows() -> Array:
	if _test_skip_db:
		var out: Array = []
		for a in _test_auctions:
			if str(a["state"]) in ["pending_sold", "pending_expired"]:
				out.append(a)
		return out
	return _auction_select("WHERE state IN ('pending_sold','pending_expired')")


static func auction_get(auction_id: int) -> Dictionary:
	for a in auction_rows(false):
		if int(a.get("id", 0)) == auction_id:
			return a
	return {}


static func auction_set_bid(auction_id: int, bidder_id: int, amount: int) -> bool:
	if _test_skip_db:
		for a in _test_auctions:
			if int(a["id"]) == auction_id:
				a["high_bid"] = amount
				a["high_bidder_id"] = bidder_id
				return true
		return false
	return _execute(
		"UPDATE market.auctions SET high_bid=$2, high_bidder_id=$3 WHERE id=$1",
		[auction_id, amount, bidder_id]
	)


static func auction_close(auction_id: int, state: String) -> bool:
	if _test_skip_db:
		for a in _test_auctions:
			if int(a["id"]) == auction_id:
				a["state"] = state
				return true
		return false
	return _execute("UPDATE market.auctions SET state=$2 WHERE id=$1", [auction_id, state])


static func auction_expired_live() -> Array:
	var out: Array = []
	for a in auction_rows(true):
		if int(a.get("expires_at_unix", 0)) <= int(Time.get_unix_time_from_system()):
			out.append(a)
	return out


# ---- durability (T-364: death penalty + repair sink) ---------------------------
# Per-equipped-row durability keyed "slot_type|slot_index". FAIL-OPEN: a slot absent from the map is
# indestructible (full-strength). SERVER-OBSERVED — wear rides the death path, repair the vendor
# op; there is NO client verb that reaches these (see the adversarial test).


static func get_durability(character_id: int) -> Dictionary:
	# {slot_key -> {current:int, max:int}} for the character's worn equipment.
	if _test_skip_db:
		return _test_durability.get(character_id, {}).duplicate(true)
	var rows := _query(
		(
			"SELECT slot_type, slot_index, current_dur, max_dur "
			+ "FROM inventory.item_durability WHERE character_id = $1"
		),
		[character_id]
	)
	var out: Dictionary = {}
	for row: Dictionary in rows:
		var key := _DUR.slot_key(str(row["slot_type"]), int(row["slot_index"]))
		out[key] = {"current": int(row["current_dur"]), "max": int(row["max_dur"])}
	return out


static func set_durability(
	character_id: int, slot_type: String, slot_index: int, current: int, max_dur: int
) -> void:
	if _test_skip_db:
		var per: Dictionary = _test_durability.get(character_id, {})
		per[_DUR.slot_key(slot_type, slot_index)] = {"current": current, "max": max_dur}
		_test_durability[character_id] = per
		return
	_execute(
		(
			"INSERT INTO inventory.item_durability "
			+ "(character_id, slot_type, slot_index, current_dur, max_dur) VALUES ($1,$2,$3,$4,$5) "
			+ "ON CONFLICT (character_id, slot_type, slot_index) "
			+ "DO UPDATE SET current_dur = $4, max_dur = $5"
		),
		[character_id, slot_type, slot_index, current, max_dur]
	)


# ---- db plumbing (character_manager idiom) --------------------------------------


static func _execute(sql: String, parameters: Array) -> bool:
	return _CM.db_execute(sql, parameters)


static func _query(sql: String, parameters: Array) -> Array:
	return _CM.db_query(sql, parameters)
