# T-036: Inventory model — pure, deterministic bag/equip/stacking logic.
#
# Operates on a character's slot list (Array of {slot_type, slot_index, item_id, item_count} —
# exactly what character_manager.get_inventory() returns) plus an injected item registry. Mirrors
# the pure-module idiom of quest_state_machine.gd (T-033), objective_tracker.gd (T-034) and
# leveling.gd (T-035): the master persists what this decides.
#
# HARD CONSTRAINTS:
#   - No DB, no OS time, no global state. Inputs are NEVER mutated (works on deep copies).
#   - Determinism: same inputs always produce identical output.
#   - Bounded by the merged T-032 schema: 16 bag slots (index 0..15) + 5 single equip slots.
#
# The item registry is INJECTED (item_id -> {slot, stackable, max_stack}); it lives in
# server/world (T-031) and master cannot preload it cross-project, so the caller passes it in —
# the same seam quest defs use. Every op returns { ok, reason, slots }; on failure the ORIGINAL
# slots come back unchanged (all-or-nothing — never a partial write).

extends RefCounted

const _ILG := preload("res://scripts/item_level_gate.gd")  # T-681: the shared required_level gate

const BAG_SLOTS := 16
const EQUIP_SLOTS := ["head", "chest", "legs", "weapon", "offhand", "shoulders"]  # T-420: pauldrons
# T-063: class -> armor types it can equip (WoW-style; warriors wear everything up to plate,
# casters cloth only). Tunable; a class not listed can equip no armor.
# T-224 (mage + priest sets): the caster armor VISUALS route on their own armor_type ("robe" for
# the mage set, "vestment" for the priest set) so the generic "cloth" family keeps its own look;
# each class is proficient with its own dedicated caster family (plus plain cloth).
const _ARMOR_PROFICIENCY := {
	"warrior": ["cloth", "leather", "mail", "plate"],
	"mage": ["cloth", "robe"],
	"priest": ["cloth", "vestment"],
}


# additions: Array of {item_id, count}. Stackable items top up existing bag stacks (lowest
# slot_index first) to max_stack, then spill into empty slots; non-stackable take one slot/unit.
static func add_items(slots: Array, additions: Array, registry: Dictionary) -> Dictionary:
	var work := _dup(slots)
	for add: Dictionary in additions:
		var item_id := str(add.get("item_id", ""))
		var count := int(add.get("count", 0))
		if not registry.has(item_id):
			return _fail("unknown_item", slots)
		if count < 1:
			return _fail("bad_count", slots)
		var def: Dictionary = registry[item_id]
		var stackable := bool(def.get("stackable", false))
		var max_stack := maxi(1, int(def.get("max_stack", 1))) if stackable else 1
		var remaining := count
		if stackable:
			for entry: Dictionary in _bag_sorted(work):
				if remaining <= 0:
					break
				if str(entry["item_id"]) == item_id and int(entry["item_count"]) < max_stack:
					var room := max_stack - int(entry["item_count"])
					var put := mini(room, remaining)
					entry["item_count"] = int(entry["item_count"]) + put
					remaining -= put
		while remaining > 0:
			var free := _first_free_bag(work)
			if free < 0:
				return _fail("bag_full", slots)
			var put := mini(max_stack, remaining)
			work.append(
				{"slot_type": "bag", "slot_index": free, "item_id": item_id, "item_count": put}
			)
			remaining -= put
	return _ok(work)


# Move a bag item to the equip slot named by its `slot`. If that slot is occupied, swap: the
# previously equipped item lands in the bag slot the new item vacated.
# T-681: `char_level` is the equip-level gate's input. It defaults to 0 = unresolved = no gate,
# the same fail-open convention `char_class == ""` uses above; the master resolves the real level
# from the persisted character row (character_manager.try_equip), never from the wire.
static func equip(
	slots: Array,
	bag_slot_index: int,
	registry: Dictionary,
	char_class: String = "",
	char_level: int = 0
) -> Dictionary:
	var work := _dup(slots)
	var src: Variant = _find(work, "bag", bag_slot_index)
	if src == null:
		return _fail("empty_slot", slots)
	var item_id := str(src["item_id"])
	if not registry.has(item_id):
		return _fail("unknown_item", slots)
	var eq_slot := str(registry[item_id].get("slot", "none"))
	if not EQUIP_SLOTS.has(eq_slot):
		return _fail("not_equippable", slots)
	# T-063: armor proficiency gate. char_class "" = no gate (tests/non-class callers); weapons and
	# misc (armor_type "none") are never gated here.
	var armor_type := str(registry[item_id].get("armor_type", "none"))
	if char_class != "" and armor_type != "none":
		if not _ARMOR_PROFICIENCY.get(char_class, []).has(armor_type):
			return _fail("wrong_armor_type", slots)
	# T-681: the equip-level gate, beside the armor gate — the SAME shared validator craft_ops
	# calls on the use_effect path, so both doors carry one rule. Server-authoritative, so it
	# covers the trade/auction twink vector by construction: a high piece can change hands and be
	# HELD by an under-level character (intended), it just cannot be worn.
	var level_refusal := _ILG.refusal(registry[item_id], char_level)
	if level_refusal != "":
		return _fail(level_refusal, slots)
	var occupant: Variant = _find(work, eq_slot, 0)
	if occupant != null:
		occupant["slot_type"] = "bag"
		occupant["slot_index"] = bag_slot_index
	src["slot_type"] = eq_slot
	src["slot_index"] = 0
	var result := _ok(work)
	result["equipped_item"] = item_id  # T-426: lets the caller credit an `equip` tutorial objective
	return result


static func unequip(slots: Array, equip_slot_type: String) -> Dictionary:
	var work := _dup(slots)
	var eq: Variant = _find(work, equip_slot_type, 0)
	if eq == null:
		return _fail("nothing_equipped", slots)
	var free := _first_free_bag(work)
	if free < 0:
		return _fail("bag_full", slots)
	eq["slot_type"] = "bag"
	eq["slot_index"] = free
	return _ok(work)


# Count-aware removal: decrements item_count, dropping the slot entirely when it hits 0.
static func remove(slots: Array, slot_type: String, slot_index: int, count: int) -> Dictionary:
	var work := _dup(slots)
	var entry: Variant = _find(work, slot_type, slot_index)
	if entry == null:
		return _fail("empty_slot", slots)
	if count < 1:
		return _fail("bad_count", slots)
	if count > int(entry["item_count"]):
		return _fail("insufficient_count", slots)
	var left := int(entry["item_count"]) - count
	if left <= 0:
		work.erase(entry)
	else:
		entry["item_count"] = left
	return _ok(work)


# item_id -> total count across BAG slots only (equip slots ignored). Bridges T-034 collect
# tracking (refresh_collect) to real inventory.
# T-058: remove up to `count` of `item_id` from BAG slots (highest slot first). Pure.
# Removes what exists (a dropped/consumed provided item just removes fewer). Returns
# {ok: true, removed: int, slots: Array}.
static func remove_item_id(slots: Array, item_id: String, count: int) -> Dictionary:
	var out: Array = slots.duplicate(true)
	var remaining: int = maxi(0, count)
	for i in range(out.size() - 1, -1, -1):
		if remaining <= 0:
			break
		var entry: Dictionary = out[i]
		if str(entry.get("slot_type", "")) != "bag" or str(entry.get("item_id", "")) != item_id:
			continue
		var have: int = int(entry.get("item_count", 0))
		var take: int = mini(have, remaining)
		remaining -= take
		if take >= have:
			out.remove_at(i)
		else:
			entry["item_count"] = have - take
			out[i] = entry
	return {"ok": true, "removed": count - remaining, "slots": out}


static func bag_item_counts(slots: Array) -> Dictionary:
	var counts: Dictionary = {}
	for entry: Dictionary in slots:
		if str(entry.get("slot_type", "")) == "bag":
			var item_id := str(entry["item_id"])
			counts[item_id] = int(counts.get(item_id, 0)) + int(entry["item_count"])
	return counts


# T-058: {item, count} rows (quest provided_items) removed in order, best-effort (a row missing
# from the bag just removes fewer, per remove_item_id's own contract).
static func remove_item_ids(slots: Array, items: Array) -> Array:
	var work := slots
	for entry: Dictionary in items:
		var item_id := str(entry.get("item", entry.get("item_id", "")))
		work = (remove_item_id(work, item_id, int(entry.get("count", 1))) as Dictionary)["slots"]
	return work


# T-661 (#51): a quest's COLLECT-type objectives name the item ("target") + count gathered — the
# item a "bring me N of these" quest hands over at turn-in. Removed here, best-effort, same as
# remove_item_ids above (a partially-lost stack just removes what's left).
static func remove_collect_objective_items(slots: Array, objectives: Array) -> Array:
	var work := slots
	for obj: Dictionary in objectives:
		if str(obj.get("type", "")) != "collect":
			continue
		var item_id := str(obj.get("target", ""))
		var count := int(obj.get("count", 1))
		if item_id == "" or count < 1:
			continue
		work = (remove_item_id(work, item_id, count) as Dictionary)["slots"]
	return work


# ---- internals -----------------------------------------------------------


static func _dup(slots: Array) -> Array:
	return slots.duplicate(true)


static func _find(work: Array, slot_type: String, slot_index: int) -> Variant:
	for entry: Dictionary in work:
		if str(entry["slot_type"]) == slot_type and int(entry["slot_index"]) == slot_index:
			return entry
	return null


static func _bag_sorted(work: Array) -> Array:
	var bag: Array = []
	for entry: Dictionary in work:
		if str(entry["slot_type"]) == "bag":
			bag.append(entry)
	bag.sort_custom(func(a, b): return int(a["slot_index"]) < int(b["slot_index"]))
	return bag


static func _first_free_bag(work: Array) -> int:
	var occupied: Dictionary = {}
	for entry: Dictionary in work:
		if str(entry["slot_type"]) == "bag":
			occupied[int(entry["slot_index"])] = true
	for i in range(BAG_SLOTS):
		if not occupied.has(i):
			return i
	return -1


static func _ok(slots: Array) -> Dictionary:
	return {"ok": true, "reason": "", "slots": slots}


static func _fail(reason: String, original: Array) -> Dictionary:
	return {"ok": false, "reason": reason, "slots": original.duplicate(true)}
