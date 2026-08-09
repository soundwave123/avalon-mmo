class_name WardrobeOps
extends RefCounted

# T-428: master-side wardrobe authority. Cosmetic state is persisted PER EQUIP SLOT, separately
# from character_items, so stat-gear swaps cannot erase a chosen look. Only decorated copies cross
# the presentation boundary; CharacterManager/combat always read the untouched item_id rows.

const _CM := preload("res://scripts/character_manager.gd")
const _CO := preload("res://scripts/cosmetics.gd")
const _CS := preload("res://scripts/cosmetic_shop.gd")  # T-476: store spend authority
const _SS := preload("res://scripts/services_store.gd")  # T-476: cosmetic_currency balance
const _GS := preload("res://scripts/guild_store.gd")  # T-679: current-guild resolution
const _GA := preload("res://scripts/guild_achievement_store.gd")  # T-679: guild-earned cosmetics

static var _test_looks: Dictionary = {}  # cid -> {slot_type -> look}
# T-548: account-owned cosmetic unlocks (source "mastery"): earned by the ACCOUNT, wearable by
# every one of its characters. Keyed on the account username, unioned into unlocks_for below.
static var _test_account_unlocks: Dictionary = {}  # account -> Array[String]


static func reset_for_test() -> void:
	_test_looks.clear()
	_test_account_unlocks.clear()


# Direct-grant hook for store/achievement/drop systems. It grants a KNOWN ID only — never a roll or
# bundle (T-482 charter: no loot boxes; there is no randomized grant verb). `source` records
# HOW it was acquired ("store" for a purchase, "grant" for achievement/drop/mentor) so a store grant
# is auditably distinct; it is data-only and never confers power. Applying the look still requires a
# server catalog definition and the persisted ownership check in op("apply").
static func grant_unlock(
	character_id: int, appearance_id: String, source: String = "grant"
) -> void:
	if character_id <= 0 or appearance_id == "":
		return
	var src := source if source != "" else "grant"
	if _CM._test_skip_db:
		var owned: Array = _CM._test_cosmetic_unlocks.get(character_id, [])
		if not appearance_id in owned:
			owned.append(appearance_id)
		_CM._test_cosmetic_unlocks[character_id] = owned
		return
	_CM.db_execute(
		(
			"INSERT INTO inventory.cosmetic_unlocks(character_id,appearance_id,source) "
			+ "VALUES($1,$2,$3) ON CONFLICT DO NOTHING"
		),
		[character_id, appearance_id, src]
	)


# T-548: account-level grant hook for account-wide earned cosmetics (mastery). The unlock is owned
# by the ACCOUNT, so it is wearable by every character on the account — current or future.
# Idempotent (ON CONFLICT DO NOTHING); `source` preserves T-482 provenance.
static func grant_account_unlock(
	account: String, appearance_id: String, source: String = "grant"
) -> void:
	if account == "" or appearance_id == "":
		return
	var src := source if source != "" else "grant"
	if _CM._test_skip_db:
		var owned: Array = _test_account_unlocks.get(account, [])
		if not appearance_id in owned:
			owned.append(appearance_id)
		_test_account_unlocks[account] = owned
		return
	_CM.db_execute(
		(
			"INSERT INTO inventory.account_cosmetic_unlocks(account,appearance_id,source) "
			+ "VALUES($1,$2,$3) ON CONFLICT DO NOTHING"
		),
		[account, appearance_id, src]
	)


# The wearable-unlock set for a character: its OWN per-character unlocks (store/drop) UNIONed with
# the ACCOUNT-owned unlocks (T-548 mastery) of the account it belongs to — so a prestige cosmetic
# the account earned is wearable on every alt, not only the one that triggered the level-up.
# T-679: ALSO unioned with the guild-earned cosmetics of the character's CURRENT guild — that
# eligibility follows membership (identity is the guild's), so leaving/being kicked drops it while
# every individually-owned unlock above is left untouched.
static func unlocks_for(character_id: int) -> Array:
	var account := str(_CM.get_character_by_id(character_id).get("username", ""))
	if _CM._test_skip_db:
		var owned: Array = (_CM._test_cosmetic_unlocks.get(character_id, []) as Array).duplicate()
		for aid: String in _test_account_unlocks.get(account, []) as Array:
			if not aid in owned:
				owned.append(aid)
		_union_guild_unlocks(owned, character_id)
		owned.sort()
		return owned
	var out: Array = []
	for row: Dictionary in _CM.db_query(
		(
			"SELECT appearance_id FROM inventory.cosmetic_unlocks WHERE character_id=$1 "
			+ "UNION SELECT appearance_id FROM inventory.account_cosmetic_unlocks WHERE account=$2 "
			+ "ORDER BY appearance_id"
		),
		[character_id, account]
	):
		out.append(str(row.get("appearance_id", "")))
	_union_guild_unlocks(out, character_id)
	return out


# Fold the current guild's earned cosmetics into `owned` (deduped). No-op for a guildless character
# — so a guild-earned look is wearable ONLY while the wearer is in the guild that earned it.
static func _union_guild_unlocks(owned: Array, character_id: int) -> void:
	var gid := _GS.guild_id_for(character_id)
	if gid <= 0:
		return
	for aid: String in _GA.guild_cosmetic_unlocks(gid):
		if not aid in owned:
			owned.append(aid)


static func looks_for(character_id: int) -> Dictionary:
	if _CM._test_skip_db:
		return (_test_looks.get(character_id, {}) as Dictionary).duplicate(true)
	var out: Dictionary = {}
	for row: Dictionary in (
		_CM
		. db_query(
			(
				"SELECT slot_type,appearance_id,display_item,armor_type,dye_id,dye_color,dye_mask,hidden "
				+ "FROM inventory.character_appearance WHERE character_id=$1 ORDER BY slot_type"
			),
			[character_id]
		)
	):
		var look := row.duplicate(true)
		look["hidden"] = _truthy(look.get("hidden", false))
		out[str(look.get("slot_type", ""))] = look
	return out


# Overlay presentation fields onto a deep copy. `item_id` and every stat-bearing field remain
# byte-identical; no look is emitted for an empty equip slot.
static func decorate_slots(character_id: int, slots: Array) -> Array:
	var out: Array = slots.duplicate(true)
	var looks := looks_for(character_id)
	for entry: Dictionary in out:
		var slot := str(entry.get("slot_type", ""))
		if not looks.has(slot):
			continue
		var look: Dictionary = looks[slot]
		if bool(look.get("hidden", false)) and slot == "head":
			entry["appearance_hidden"] = true
		var display_item := str(look.get("display_item", ""))
		if display_item != "":
			entry["appearance_override"] = display_item
			entry["appearance_armor_type"] = str(look.get("armor_type", "none"))
			var color := str(look.get("dye_color", ""))
			if color != "":
				entry["tint"] = color
				entry["dye_mask"] = str(look.get("dye_mask", "all"))
	return out


static func op(params: Dictionary) -> Dictionary:
	var character := _CM.get_character(str(params.get("username", "")))
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character"}
	var cid := int(character.get("id", -1))
	match str(params.get("action", "")):
		"list":
			return _state(cid)
		"purchase":
			# T-476 store spend. `appearance` is the priced catalog row the WORLD resolved from
			# wardrobe.json (server-authoritative) — never client data. On success the granted look
			# joins the unlock set, so return the refreshed wardrobe state alongside the balance.
			var bought := _CS.purchase(
				cid, params.get("appearance", {}), str(params.get("username", ""))
			)
			if not bool(bought.get("ok", false)):
				return {
					"ok": false,
					"reason": str(bought.get("reason", "rejected")),
					"cosmetic_currency": int(bought.get("balance", 0)),
				}
			var state := _state(cid)
			state["cosmetic_currency"] = int(bought.get("balance", 0))
			state["purchased"] = str(bought.get("appearance_id", ""))
			return state
		"apply":
			var built := _CO.build_wardrobe_look(
				_CM.get_inventory(cid),
				str(params.get("slot", "")),
				params.get("appearance", {}),
				params.get("dye", {}),
				unlocks_for(cid)
			)
			if not bool(built.get("ok", false)):
				return {"ok": false, "reason": str(built.get("reason", "rejected"))}
			_persist_look(cid, built["look"])
			return _state(cid)
		"clear":
			var slot := str(params.get("slot", ""))
			if not slot in _CO.OVERRIDE_SLOTS:
				return {"ok": false, "reason": "not_a_gear_slot"}
			_clear_display(cid, slot)
			return _state(cid)
		"toggle_hide_helm":
			var head: Dictionary = looks_for(cid).get("head", {"slot_type": "head"})
			head["hidden"] = not bool(head.get("hidden", false))
			_persist_look(cid, head)
			return _state(cid)
	return {"ok": false, "reason": "bad_action"}


static func _state(cid: int) -> Dictionary:
	return {
		"ok": true,
		"slots": decorate_slots(cid, _CM.get_inventory(cid)),
		"unlocks": unlocks_for(cid),
		"looks": looks_for(cid),
		"cosmetic_currency": _SS.get_cosmetic_currency(cid),
	}


static func _clear_display(cid: int, slot: String) -> void:
	var look: Dictionary = looks_for(cid).get(slot, {})
	if bool(look.get("hidden", false)) and slot == "head":
		_persist_look(cid, {"slot_type": slot, "hidden": true})
	elif not look.is_empty():
		_delete_look(cid, slot)


static func _persist_look(cid: int, look: Dictionary) -> void:
	var slot := str(look.get("slot_type", ""))
	if _CM._test_skip_db:
		var stored: Dictionary = _test_looks.get(cid, {})
		stored[slot] = look.duplicate(true)
		_test_looks[cid] = stored
		return
	(
		_CM
		. db_execute(
			(
				"INSERT INTO inventory.character_appearance "
				+ "(character_id,slot_type,appearance_id,display_item,armor_type,dye_id,"
				+ "dye_color,dye_mask,hidden) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) "
				+ "ON CONFLICT(character_id,slot_type) DO UPDATE SET appearance_id=$3,"
				+ "display_item=$4,armor_type=$5,dye_id=$6,dye_color=$7,dye_mask=$8,hidden=$9"
			),
			[
				cid,
				slot,
				str(look.get("appearance_id", "")),
				str(look.get("display_item", "")),
				str(look.get("armor_type", "none")),
				str(look.get("dye_id", "")),
				str(look.get("dye_color", "")),
				str(look.get("dye_mask", "all")),
				bool(look.get("hidden", false)),
			]
		)
	)


static func _delete_look(cid: int, slot: String) -> void:
	if _CM._test_skip_db:
		var stored: Dictionary = _test_looks.get(cid, {})
		stored.erase(slot)
		_test_looks[cid] = stored
		return
	_CM.db_execute(
		"DELETE FROM inventory.character_appearance WHERE character_id=$1 AND slot_type=$2",
		[cid, slot]
	)


static func _truthy(value: Variant) -> bool:
	return value if value is bool else str(value).to_lower() in ["t", "true", "1"]
