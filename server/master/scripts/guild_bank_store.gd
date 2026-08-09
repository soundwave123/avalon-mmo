class_name GuildBankStore
extends RefCounted

# T-683: the guild BANK — a rank-gated, ledgered shared coin/item vault keyed on the guild id
# (chars.guild_bank / chars.guild_bank_item, migration 052). The shared-SPACE half of the guild
# loop (T-679 shipped the shared IDENTITY/trophy half). Carved into its own module so
# guild_store.gd stays under the 1000-line cap; guild_store.op() resolves the actor's PERSISTED
# membership+rank and delegates here (the client never asserts a rank — same discipline as every
# T-362 management verb).
#
# SERVER-AUTHORITY + NET-ZERO (T-470/T-609):
#   - Deposit is open to any member; WITHDRAW is gated through GuildLogic (Officer+), with a
#     per-rank per-withdrawal coin cap. The gate reads the actor's persisted rank via GuildStore.
#   - Every coin move writes the player's own econ.coin_ledger row in the SAME transaction as the
#     balance change, so per-character reconciliation (characters.coins == sum(ledger.delta)) stays
#     exact. The guild vault is a HOLDING account (not a character), so it is OFF that reconcile:
#     deposit classifies SINK-side (coin leaves the player supply), withdraw FAUCET-side (returns).
#     A deposit+withdraw cycle is net-zero and never mints new money.
#   - Every move is ATOMIC + fail-closed: debit and credit ride one BEGIN..COMMIT, and the coins>=0
#     CHECK on both chars.characters and chars.guild_bank rolls the WHOLE move back on an over-draw
#     — an interrupted/over-withdraw attempt leaves BOTH balances intact (no dupe, no loss). Item
#     moves splice the player-inventory rewrite and the vault row change into one transaction too.
#
# NOT POWER (T-679/T-482 charter): the vault holds coin + ordinary item_id/count ONLY. Nothing here
# reads or grants a stat/xp/rested/cheaper/content-entry field — it is a shared wallet.

const _CM := preload("res://scripts/character_manager.gd")
const _SS := preload("res://scripts/services_store.gd")
const _CL := preload("res://scripts/coin_ledger.gd")
const _IL := preload("res://scripts/inventory_logic.gd")
const _IP := preload("res://scripts/inventory_persist.gd")
const GuildLogic := preload("res://scripts/guild_logic.gd")

const REASON_DEPOSIT := "guild_bank_deposit"  # sink-side (wallet -> bank)
const REASON_WITHDRAW := "guild_bank_withdraw"  # faucet-side (bank -> wallet); also disband payout

static var _test_coins: Dictionary = {}  # gid -> int (copper)
static var _test_items: Dictionary = {}  # gid -> {item_id: count}


static func reset_for_test() -> void:
	_test_coins.clear()
	_test_items.clear()


# ---- reads -----------------------------------------------------------------------


static func get_coins(gid: int) -> int:
	if _CM._test_skip_db:
		return int(_test_coins.get(gid, 0))
	var rows := _CM.db_query("SELECT coins FROM chars.guild_bank WHERE guild_id = $1", [gid])
	return int(rows[0].get("coins", 0)) if not rows.is_empty() else 0


static func _items(gid: int) -> Dictionary:
	if _CM._test_skip_db:
		return (_test_items.get(gid, {}) as Dictionary).duplicate()
	var out: Dictionary = {}
	for row in _CM.db_query(
		"SELECT item_id, item_count FROM chars.guild_bank_item WHERE guild_id = $1", [gid]
	):
		out[str(row.get("item_id", ""))] = int(row.get("item_count", 0))
	return out


# The read-only bank view for the panel: pooled coin + the ordinary-item stacks it holds.
static func view(gid: int) -> Dictionary:
	var items: Array = []
	var raw := _items(gid)
	for item_id: String in raw:
		items.append({"item_id": item_id, "item_count": int(raw[item_id])})
	items.sort_custom(func(a, b): return str(a["item_id"]) < str(b["item_id"]))
	return {"ok": true, "guild_id": gid, "bank_coins": get_coins(gid), "items": items}


# ---- coin moves ------------------------------------------------------------------


# Deposit: open to any member. Debits the actor's wallet and credits the vault ATOMICALLY.
static func deposit_coins(cid: int, gid: int, rank: int, amount: int) -> Dictionary:
	if not GuildLogic.can_deposit_bank(rank):
		return {"error": "no_permission"}
	if amount <= 0:
		return {"error": "bad_amount"}
	if _SS.get_coins(cid) < amount:  # clean rejection; the CHECK is the atomic backstop
		return {"error": "insufficient_coins"}
	if _CM._test_skip_db:
		if not _SS.adjust_coins(cid, -amount, REASON_DEPOSIT):
			return {"error": "insufficient_coins"}
		_test_coins[gid] = get_coins(gid) + amount
	else:
		var ok := (
			_CM
			. db_execute(
				(
					"BEGIN;\n"
					+ "UPDATE chars.characters SET coins = coins - $1 WHERE id = $2;\n"
					+ "INSERT INTO econ.coin_ledger (character_id, delta, reason) VALUES ($3, $4, $5);\n"
					+ "INSERT INTO chars.guild_bank (guild_id, coins) VALUES ($6, $7) "
					+ "ON CONFLICT (guild_id) DO UPDATE SET coins = chars.guild_bank.coins + $8;\n"
					+ "COMMIT;"
				),
				[amount, cid, cid, -amount, REASON_DEPOSIT, gid, amount, amount]
			)
		)
		if not ok:
			return {"error": "move_failed"}  # CHECK rolled it back — both balances intact
	return {"ok": true, "deposited": amount, "bank_coins": get_coins(gid)}


# Withdraw: Officer+ only, capped per rank. Debits the vault, credits the wallet — ATOMICALLY.
static func withdraw_coins(cid: int, gid: int, rank: int, amount: int) -> Dictionary:
	if not GuildLogic.can_withdraw_bank(rank):
		return {"error": "no_permission"}
	if amount <= 0:
		return {"error": "bad_amount"}
	var cap := GuildLogic.bank_withdraw_cap(rank)
	if cap >= 0 and amount > cap:
		return {"error": "over_cap", "cap": cap}
	if get_coins(gid) < amount:  # clean rejection; the CHECK is the atomic backstop
		return {"error": "insufficient_bank_coins"}
	if _CM._test_skip_db:
		_test_coins[gid] = get_coins(gid) - amount
		if not _SS.adjust_coins(cid, amount, REASON_WITHDRAW):  # never fails on a credit
			_test_coins[gid] = get_coins(gid) + amount  # unreachable; keep the vault whole if it did
			return {"error": "move_failed"}
	else:
		var ok := (
			_CM
			. db_execute(
				(
					"BEGIN;\n"
					+ "UPDATE chars.guild_bank SET coins = coins - $1 WHERE guild_id = $2;\n"
					+ "UPDATE chars.characters SET coins = coins + $3 WHERE id = $4;\n"
					+ "INSERT INTO econ.coin_ledger (character_id, delta, reason) VALUES ($5, $6, $7);\n"
					+ "COMMIT;"
				),
				[amount, gid, amount, cid, cid, amount, REASON_WITHDRAW]
			)
		)
		if not ok:
			return {"error": "move_failed"}  # CHECK rolled it back — both balances intact
	return {"ok": true, "withdrew": amount, "bank_coins": get_coins(gid)}


# ---- item moves ------------------------------------------------------------------


# Deposit one bag stack into the vault. Open to any member. Removes it from the actor's persisted
# inventory and adds it to the guild vault in ONE transaction (T-609: no dupe, no loss).
static func deposit_item(
	cid: int, gid: int, rank: int, slot_index: int, count: int, _registry: Dictionary = {}
) -> Dictionary:
	if not GuildLogic.can_deposit_bank(rank):
		return {"error": "no_permission"}
	if count <= 0:
		return {"error": "bad_count"}
	var inv := _CM.get_inventory(cid)
	var item_id := _bag_item_id(inv, slot_index)
	if item_id == "":
		return {"error": "empty_slot"}
	var removed := _IL.remove(inv, "bag", slot_index, count)
	if not bool(removed.get("ok", false)):
		return {"error": str(removed.get("reason", "remove_failed"))}
	var new_slots: Array = removed["slots"]
	if _CM._test_skip_db:
		if not _CM._persist_inventory(cid, new_slots):  # honours the T-567 atomic-reject injection
			return {"error": "move_failed"}  # vault untouched — nothing moved
		_vault_add_test(gid, item_id, count)
	else:
		var stmts: Array = ["BEGIN;"]
		var params: Array = []
		_IP.append_persist(cid, new_slots, stmts, params)
		params.append_array([gid, item_id, count, count])
		stmts.append(
			(
				(
					"INSERT INTO chars.guild_bank_item (guild_id, item_id, item_count) "
					+ "VALUES ($%d, $%d, $%d) ON CONFLICT (guild_id, item_id) "
					+ "DO UPDATE SET item_count = chars.guild_bank_item.item_count + $%d;"
				)
				% [params.size() - 3, params.size() - 2, params.size() - 1, params.size()]
			)
		)
		stmts.append("COMMIT;")
		if not _CM.db_execute("\n".join(stmts), params):
			return {"error": "move_failed"}
	return {"ok": true, "deposited_item": item_id, "count": count}


# Withdraw a stack from the vault into the actor's bag. Officer+ only. Vault debit + inventory add
# ride one transaction; a bag-full add or an over-withdraw moves NOTHING.
static func withdraw_item(
	cid: int, gid: int, rank: int, item_id: String, count: int, registry: Dictionary
) -> Dictionary:
	if not GuildLogic.can_withdraw_bank(rank):
		return {"error": "no_permission"}
	if count <= 0:
		return {"error": "bad_count"}
	var have := int(_items(gid).get(item_id, 0))
	if have < count:
		return {"error": "insufficient_bank_items"}  # over-withdraw — nothing moves
	var added := _IL.add_items(
		_CM.get_inventory(cid), [{"item_id": item_id, "count": count}], registry
	)
	if not bool(added.get("ok", false)):
		return {"error": str(added.get("reason", "bag_full"))}  # no room — nothing moves
	var new_slots: Array = added["slots"]
	if _CM._test_skip_db:
		if not _CM._persist_inventory(cid, new_slots):
			return {"error": "move_failed"}  # vault untouched — nothing moved
		_vault_take_test(gid, item_id, count)
	else:
		var stmts: Array = ["BEGIN;"]
		var params: Array = []
		_IP.append_persist(cid, new_slots, stmts, params)
		_append_vault_take(gid, item_id, count, have, stmts, params)
		stmts.append("COMMIT;")
		if not _CM.db_execute("\n".join(stmts), params):
			return {"error": "move_failed"}
	return {"ok": true, "withdrew_item": item_id, "count": count}


# ---- disband resolution (documented rule) ----------------------------------------


# T-683 DISBAND RULE: the bank's coin balance AND item stacks are returned to the LEADER on disband,
# so no coin/item is orphaned or duped on the way out. Coin always fits a wallet; items are added to
# the leader's bags up to capacity and any OVERFLOW is FORFEITED as a sink (documented fallback — a
# full-bag leader never blocks the disband, and the forfeited stack is destroyed, never duped). Runs
# BEFORE GuildStore._delete_guild so the payout lands before the ON DELETE CASCADE clears the vault.
static func resolve_on_disband(gid: int, leader_id: int, registry: Dictionary) -> Dictionary:
	var coins := get_coins(gid)
	if coins > 0:
		if _CM._test_skip_db:
			_SS.adjust_coins(leader_id, coins, REASON_WITHDRAW)
			_test_coins[gid] = 0
		else:
			(
				_CM
				. db_execute(
					(
						"BEGIN;\n"
						+ "UPDATE chars.characters SET coins = coins + $1 WHERE id = $2;\n"
						+ "INSERT INTO econ.coin_ledger (character_id, delta, reason) VALUES ($3,$4,$5);\n"
						+ "UPDATE chars.guild_bank SET coins = 0 WHERE guild_id = $6;\n"
						+ "COMMIT;"
					),
					[coins, leader_id, leader_id, coins, REASON_WITHDRAW, gid]
				)
			)
	var returned: Array = []
	var forfeited: Array = []
	var vault := _items(gid)
	# Greedy per-stack add so a partial-capacity leader keeps as much as fits; the rest forfeits.
	var slots := _CM.get_inventory(leader_id)
	for item_id: String in vault:
		var count := int(vault[item_id])
		var attempt := _IL.add_items(slots, [{"item_id": item_id, "count": count}], registry)
		if bool(attempt.get("ok", false)):
			slots = attempt["slots"]
			returned.append({"item_id": item_id, "item_count": count})
		else:
			forfeited.append({"item_id": item_id, "item_count": count})
	if not vault.is_empty():
		_CM._persist_inventory(leader_id, slots)
		_clear_vault_items(gid)
	return {"coins_returned": coins, "items_returned": returned, "items_forfeited": forfeited}


# ---- vault storage primitives (test-fake ↔ DB) -----------------------------------


static func _bag_item_id(inv: Array, slot_index: int) -> String:
	for entry: Dictionary in inv:
		if (
			str(entry.get("slot_type", "")) == "bag"
			and int(entry.get("slot_index", -1)) == slot_index
		):
			return str(entry.get("item_id", ""))
	return ""


static func _vault_add_test(gid: int, item_id: String, count: int) -> void:
	var v: Dictionary = _test_items.get(gid, {})
	v[item_id] = int(v.get(item_id, 0)) + count
	_test_items[gid] = v


static func _vault_take_test(gid: int, item_id: String, count: int) -> void:
	var v: Dictionary = _test_items.get(gid, {})
	var left := int(v.get(item_id, 0)) - count
	if left <= 0:
		v.erase(item_id)
	else:
		v[item_id] = left
	_test_items[gid] = v


# Withdrawing the WHOLE stack DELETEs the row (the item_count>0 CHECK forbids leaving a 0 row);
# a partial withdraw decrements it. `have` is the pre-validated vault count.
static func _append_vault_take(
	gid: int, item_id: String, count: int, have: int, stmts: Array, params: Array
) -> void:
	if count >= have:
		params.append_array([gid, item_id])
		stmts.append(
			(
				"DELETE FROM chars.guild_bank_item WHERE guild_id = $%d AND item_id = $%d;"
				% [params.size() - 1, params.size()]
			)
		)
	else:
		params.append_array([count, gid, item_id])
		stmts.append(
			(
				(
					"UPDATE chars.guild_bank_item SET item_count = item_count - $%d "
					+ "WHERE guild_id = $%d AND item_id = $%d;"
				)
				% [params.size() - 2, params.size() - 1, params.size()]
			)
		)


static func _clear_vault_items(gid: int) -> void:
	if _CM._test_skip_db:
		_test_items.erase(gid)
		return
	_CM.db_execute("DELETE FROM chars.guild_bank_item WHERE guild_id = $1", [gid])
