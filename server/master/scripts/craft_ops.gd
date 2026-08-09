class_name CraftOps
extends RefCounted

# T-414: master-owned crafting ops — the *Ops-module extraction pattern (durability_ops/vault_ops).
# Every op resolves identity from the username the WORLD passed (session-derived), never the wire;
# every item/effect/output is named by SERVER data (world node/recipe registries + item_registry),
# never the client. Pure of Node state: persistence rides CharacterManager/ServicesStore, so tests
# drive these statics directly against the in-memory backend.
#
# ECON NOTE (T-366): gather_op MINTS materials — a faucet tracked BY ITEM (inventory rows), not
# coin; the coin ledger is untouched by gather/craft/use. The only coin move on this surface is
# recipe_op "learn" — a SINK debited via adjust_coins reason "recipe" (lands in econ.coin_ledger).

const CharacterManager := preload("res://scripts/character_manager.gd")
const _IL := preload("res://scripts/inventory_logic.gd")
const _ILG := preload("res://scripts/item_level_gate.gd")  # T-681: shared required_level gate
const _IP := preload("res://scripts/inventory_persist.gd")  # T-567: wearable-unlock derivation
const _ACH := preload("res://scripts/achievement_store.gd")  # T-676: gather/craft/recipe emits
const _KCO := preload("res://scripts/kill_credit_ops.gd")  # T-679: shared credit_guild seam


# Mint a gather yield into the bag. item_id/count come from the WORLD's node registry (the client
# named only a node id, proximity-gated world-side). Returns inventory_logic's {ok, reason, slots}.
static func gather_op(params: Dictionary) -> Dictionary:
	var cid := _char_id(params)
	if cid < 0:
		return {"error": "unknown_character"}
	var item_id := str(params.get("item_id", ""))
	var additions: Array = [{"item_id": item_id, "count": int(params.get("count", 0))}]
	# T-677: an ADDITIVE rare cross-find (herb/ore/timber proc) rides alongside the guaranteed
	# primary yield when the world rolled one — both mint in the SAME transactional add, so the proc
	# never displaces the primary. Empty/absent bonus (fishing, legacy nodes) is a no-op.
	var bonus: Dictionary = params.get("bonus", {})
	if not bonus.is_empty() and str(bonus.get("item_id", "")) != "":
		additions.append(
			{"item_id": str(bonus["item_id"]), "count": maxi(1, int(bonus.get("count", 1)))}
		)
	var result: Dictionary = CharacterManager.try_add_items(
		cid, additions, params.get("item_registry", {})
	)
	# T-676: one credited gather action advances the gather counter (running total + per-material).
	# Fires only on a real minted yield (never a bag-full/invalid no-op), the same server-observed
	# seam kill/discovery use — the client never reaches AchievementStore.
	if bool(result.get("ok", false)):
		_merge_achievements(result, _ACH.observe(cid, "gather", item_id))
		# T-679: roster-total gathers, credited to the actor's current guild (no-op if guildless).
		_KCO.credit_guild(result, cid, "guild_gather", item_id)
	return result


# list: the character's known recipe ids. learn: validate not-known + debit the ledgered "recipe"
# coin sink (overdraft-guarded) + grant. The recipe def (id, coin_cost) is world-supplied content —
# the same content-authority seam quest defs ride; the client never names a cost.
static func recipe_op(params: Dictionary) -> Dictionary:
	var cid := _char_id(params)
	if cid < 0:
		return {"error": "unknown_character"}
	if str(params.get("action", "list")) == "learn":
		var recipe: Dictionary = params.get("recipe", {})
		var rid := str(recipe.get("id", ""))
		if rid == "":
			return {"error": "unknown_recipe"}
		if rid in ServicesStore.get_known_recipes(cid):
			return {"error": "already_known"}
		if not ServicesStore.adjust_coins(cid, -maxi(0, int(recipe.get("coin_cost", 0))), "recipe"):
			return {"error": "insufficient_coins"}
		ServicesStore.grant_recipe(cid, rid)
		# T-676: learning a NEW recipe flags it (recipe:<rid>) + advances the unique total (recipe:*),
		# powering "learn your first recipe" and the "learn every recipe" completionist wall.
		var result := {
			"known": ServicesStore.get_known_recipes(cid), "coins": ServicesStore.get_coins(cid)
		}
		_merge_achievements(result, _ACH.observe(cid, "recipe", rid))
		return result
	return {"known": ServicesStore.get_known_recipes(cid), "coins": ServicesStore.get_coins(cid)}


# Craft: recipe known → every input owned → inputs consumed → output granted, ALL-OR-NOTHING.
# The whole change is computed on a working copy and persisted in ONE transactional write
# (inventory_persist discipline) — any shortfall/bag-full aborts with the stored rows untouched.
# The output is SERVER-NAMED from the world-resolved recipe def; the client sent only a recipe_id.
static func craft_op(params: Dictionary) -> Dictionary:
	var cid := _char_id(params)
	if cid < 0:
		return {"error": "unknown_character"}
	var recipe: Dictionary = params.get("recipe", {})
	var rid := str(recipe.get("id", ""))
	if rid == "":
		return {"error": "unknown_recipe"}
	if not (rid in ServicesStore.get_known_recipes(cid)):
		return {"error": "recipe_not_known"}
	var work: Array = CharacterManager.get_inventory(cid).duplicate(true)
	for input: Dictionary in recipe.get("inputs", []):
		var need := int(input.get("count", 0))
		if need < 1:
			return {"error": "bad_recipe"}
		var removed := _IL.remove_item_id(work, str(input.get("item", "")), need)
		if int(removed["removed"]) < need:
			return {"error": "missing_materials"}
		work = removed["slots"]
	var output: Dictionary = recipe.get("output", {})
	var added := _IL.add_items(
		work,
		[{"item_id": str(output.get("item", "")), "count": int(output.get("count", 1))}],
		params.get("item_registry", {})
	)
	if not bool(added["ok"]):
		return {"error": str(added["reason"])}
	CharacterManager._persist_inventory(
		cid, added["slots"], _IP.wearable_appearance_ids([output], params.get("item_registry", {}))
	)  # single write + first-acquisition look unlock
	# T-676: a completed craft advances the craft counter (running total + per-recipe) for the
	# first-craft + craft-count achievements.
	var result := {"ok": true, "slots": added["slots"]}
	_merge_achievements(result, _ACH.observe(cid, "craft", rid))
	return result


# Use a consumable: the client named ONLY a bag slot_index. The item resolves from the PERSISTED
# inventory at that slot; its effect resolves from item DATA (item_registry.use_effect) — a forged
# effect/item in params is never read. Consume-then-apply: rested/repair apply here (master state);
# a heal effect rides back to the world, which applies it to live HP server-side.
static func use_item_op(params: Dictionary) -> Dictionary:
	var cid := _char_id(params)
	if cid < 0:
		return {"error": "unknown_character"}
	var slot_index := int(params.get("slot_index", -1))
	var slots: Array = CharacterManager.get_inventory(cid)
	var item_id := ""
	for entry: Dictionary in slots:
		if str(entry["slot_type"]) == "bag" and int(entry["slot_index"]) == slot_index:
			item_id = str(entry["item_id"])
			break
	if item_id == "":
		return {"error": "empty_slot"}
	var registry: Dictionary = params.get("item_registry", {})
	var item_def: Dictionary = registry.get(item_id, {})
	var effect: Dictionary = item_def.get("use_effect", {})
	if not (effect is Dictionary) or effect.is_empty():
		return {"error": "not_usable"}
	# T-681: the SECOND door into the level gate. This path never touches inventory_logic.equip(),
	# so a check written only there would leave every consumable (and any future enchant/augment
	# resolving the same way) ungated. Same shared validator, same character-row authority — the
	# level is read from the persisted row, never from params.
	var char_level := int(CharacterManager.get_character_by_id(cid).get("level", 1))
	if not _ILG.meets(item_def, char_level):
		return {"error": _ILG.REASON}
	var removed := _IL.remove(slots, "bag", slot_index, 1)
	if not bool(removed["ok"]):
		return {"error": str(removed["reason"])}
	CharacterManager._persist_inventory(cid, removed["slots"])
	var out := {"ok": true, "slots": removed["slots"], "effect": effect.duplicate(true)}
	match str(effect.get("kind", "")):
		"rested":  # T-360 coupling — cap-clamped comfort grant (anti-abuse: never exceeds the cap)
			out["rested_remaining"] = CharacterManager.grant_rested(
				cid, maxi(0, int(effect.get("amount", 0)))
			)
		"repair":  # T-412 coupling — partial field repair, worse than the vendor's full restore
			out["repaired"] = _field_repair(cid, clampf(float(effect.get("pct", 0.0)), 0.0, 1.0))
	return out


# Restore pct-of-max to every worn slot (clamped). Returns how many slots improved.
static func _field_repair(cid: int, pct: float) -> int:
	var dur: Dictionary = ServicesStore.get_durability(cid)
	var repaired := 0
	for key in dur:
		var mx := int(dur[key]["max"])
		var cur := int(dur[key]["current"])
		if cur >= mx:
			continue
		var parts: PackedStringArray = str(key).split("|")
		ServicesStore.set_durability(
			cid, str(parts[0]), int(parts[1]), mini(mx, cur + int(ceil(pct * float(mx)))), mx
		)
		repaired += 1
	return repaired


static func _char_id(params: Dictionary) -> int:
	var username := str(params.get("username", ""))
	CharacterManager.ensure_character(username)
	var character := CharacterManager.get_character(username)
	return int(character["id"]) if not character.is_empty() else -1


# T-367/T-676: fold any newly-earned achievements into an op result so the world can toast the
# earner (mirrors kill_credit_ops.merge_achievements). A no-op when nothing newly completed.
static func _merge_achievements(result: Dictionary, observed: Dictionary) -> void:
	var earned: Array = observed.get("newly_earned", [])
	if not earned.is_empty():
		result["achievements"] = (result.get("achievements", []) as Array) + earned
