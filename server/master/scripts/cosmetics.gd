# T-375: cosmetic / transmog data seam — the monetization-canon seam (game-direction.md §1.6/§4:
# "Cosmetics-only store... Power is NEVER for sale"). Pure, server-authoritative helpers in the
# inventory_logic style — no DB handle, no OS time, no global state — that reserve the seam BEFORE
# more gear ships, so appearance stays separable from stat gear instead of being retrofitted later.
#
# The seam splits an equipped slot into two channels:
#   STATS channel      = `item_id` (+ item_count) — the ONLY thing combat/stats ever read.
#   APPEARANCE channel = optional `appearance_override` ("shown as" visual id) + `tint` (reserved
#                        dye). broadcast_builder.equipped_from_slots renders the override when
#                        present, else the real item — so nothing changes visually until a transmog
#                        is set and stats NEVER move (the override is cosmetic-only).
#
# Server-authority (standing orders): appearance is server-stored state, NEVER a client-asserted
# packet. T-428's write path resolves catalog ids world-side, then build_wardrobe_look FAILS CLOSED
# unless the appearance id is in `inventory.cosmetic_unlocks`. The slot-level persisted look,
# acquisition/store grant hooks, client dye renderer, and forged-request coverage now complete the
# seam without exposing a stat-bearing field.

extends RefCounted

# The equip slot_types that carry a visible appearance channel — the paper-doll (mirrors
# broadcast_builder.GEAR_SLOTS). Bag/vault items are never worn, so they have no appearance channel.
const OVERRIDE_SLOTS := ["weapon", "offhand", "head", "chest", "legs", "shoulders"]
const _POWER_FIELDS := ["stats", "attack", "armor", "damage", "power", "bonuses", "effects"]


# Is `appearance_id` unlocked for this character? `unlocks` is the character's unlock set — an Array
# of appearance_id strings (the cosmetic_unlocks rows). Fails closed: an empty id is never valid.
static func can_apply(unlocks, appearance_id: String) -> bool:
	if appearance_id == "":
		return false
	return appearance_id in unlocks


# Set the cosmetic appearance override (+ optional dye `tint`) on an equipped slot. Returns
# {ok, reason, slots}; NOTHING mutates on failure (all-or-nothing, like inventory_logic). FAILS
# CLOSED — rejected unless the target is a real gear slot, the appearance is unlocked, and the slot
# is actually equipped. `item_id`/`item_count` are NEVER touched, so stats stay the real item's.
# `tint` is a reserved dye field (a hex/palette string): stored when non-empty, not yet broadcast.
static func apply_override(
	slots: Array, equip_slot_type: String, appearance_id: String, tint: String, unlocks
) -> Dictionary:
	if not equip_slot_type in OVERRIDE_SLOTS:
		return {"ok": false, "reason": "not_a_gear_slot", "slots": slots}
	if not can_apply(unlocks, appearance_id):
		return {"ok": false, "reason": "not_unlocked", "slots": slots}
	var work: Array = slots.duplicate(true)
	var slot: Variant = _find_equipped(work, equip_slot_type)
	if slot == null:
		return {"ok": false, "reason": "slot_empty", "slots": slots}
	slot["appearance_override"] = appearance_id
	if tint != "":
		slot["tint"] = tint
	else:
		slot.erase("tint")
	return {"ok": true, "reason": "", "slots": work}


# Remove the cosmetic override (+ tint) from an equipped slot — the item renders as its real self
# again. Returns {ok, reason, slots}; fails only if the slot is empty (never equipped).
static func clear_override(slots: Array, equip_slot_type: String) -> Dictionary:
	var work: Array = slots.duplicate(true)
	var slot: Variant = _find_equipped(work, equip_slot_type)
	if slot == null:
		return {"ok": false, "reason": "slot_empty", "slots": slots}
	slot.erase("appearance_override")
	slot.erase("tint")
	return {"ok": true, "reason": "", "slots": work}


# T-428: validate a catalog-resolved appearance + dye and build the persisted PRESENTATION row.
# The caller supplies only server-authored definitions; this layer still rejects any power-bearing
# shape defensively. The returned look contains no stat field and never rewrites the inventory.
static func build_wardrobe_look(
	slots: Array, equip_slot_type: String, appearance: Dictionary, dye: Dictionary, unlocks: Array
) -> Dictionary:
	if not equip_slot_type in OVERRIDE_SLOTS:
		return {"ok": false, "reason": "not_a_gear_slot"}
	for field: String in _POWER_FIELDS:
		if appearance.has(field) or dye.has(field):
			return {"ok": false, "reason": "power_field"}
	var appearance_id := str(appearance.get("id", ""))
	var display_item := str(appearance.get("display_item", ""))
	if appearance_id == "" or display_item == "":
		return {"ok": false, "reason": "bad_appearance"}
	if str(appearance.get("slot", "")) != equip_slot_type:
		return {"ok": false, "reason": "wrong_slot"}
	if not can_apply(unlocks, appearance_id):
		return {"ok": false, "reason": "not_unlocked"}
	if _find_equipped(slots, equip_slot_type) == null:
		return {"ok": false, "reason": "slot_empty"}
	var dye_id := str(dye.get("id", ""))
	var dye_color := str(dye.get("color", ""))
	if (dye_id == "") != (dye_color == ""):
		return {"ok": false, "reason": "bad_dye"}
	if dye_color != "" and not dye_color.is_valid_html_color():
		return {"ok": false, "reason": "bad_dye"}
	return {
		"ok": true,
		"reason": "",
		"look":
		{
			"slot_type": equip_slot_type,
			"appearance_id": appearance_id,
			"display_item": display_item,
			"armor_type": str(appearance.get("armor_type", "none")),
			"dye_id": dye_id,
			"dye_color": dye_color,
			"dye_mask": str(appearance.get("dye_mask", "all")),
			"hidden": false,
		}
	}


static func _find_equipped(work: Array, equip_slot_type: String) -> Variant:
	for entry in work:
		if entry is Dictionary and str(entry.get("slot_type", "")) == equip_slot_type:
			return entry
	return null
