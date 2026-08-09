extends GutTest
# T-375: the cosmetic / transmog data seam. Appearance is a server-authoritative, unlock-gated
# channel separate from stat gear — proven pure here so the future wardrobe/store plugs in cleanly.

const _CO = preload("res://scripts/cosmetics.gd")


func _equipped() -> Array:
	return [
		{"slot_type": "bag", "slot_index": 0, "item_id": "itm_wolf_pelt", "item_count": 3},
		{"slot_type": "weapon", "slot_index": 0, "item_id": "itm_iron_sword", "item_count": 1},
		{"slot_type": "chest", "slot_index": 0, "item_id": "itm_leather_vest", "item_count": 1},
	]


# --- the unlock gate: a client can never wear a look it hasn't unlocked -------------------------


func test_can_apply_requires_membership_and_rejects_empty() -> void:
	var unlocks := ["cos_gilded_blade", "cos_dread_plate"]
	assert_true(_CO.can_apply(unlocks, "cos_gilded_blade"), "an unlocked id applies")
	assert_false(_CO.can_apply(unlocks, "cos_never_unlocked"), "a not-unlocked id is rejected")
	assert_false(_CO.can_apply(unlocks, ""), "empty id is never valid")
	assert_false(_CO.can_apply([], "cos_gilded_blade"), "empty unlock set applies nothing")


func test_apply_override_rejects_locked_appearance() -> void:
	var before := _equipped()
	var res := _CO.apply_override(before, "weapon", "cos_forbidden", "", ["cos_gilded_blade"])
	assert_false(res["ok"], "a locked appearance is refused")
	assert_eq(res["reason"], "not_unlocked")
	# fail-closed: nothing mutated.
	for entry: Dictionary in res["slots"]:
		assert_false(entry.has("appearance_override"), "no override written on rejection")


# --- the happy path: appearance overrides, stats stay put --------------------------------------


func test_apply_override_sets_appearance_only_not_stats() -> void:
	var res := _CO.apply_override(
		_equipped(), "weapon", "cos_gilded_blade", "#c0a060", ["cos_gilded_blade"]
	)
	assert_true(res["ok"])
	var slots: Array = res["slots"]
	var weapon: Dictionary = _slot(slots, "weapon")
	assert_eq(weapon["appearance_override"], "cos_gilded_blade", "the shown-as visual is set")
	assert_eq(weapon["tint"], "#c0a060", "the reserved dye tint is stored")
	# STATS channel untouched — the real item and count are exactly as before.
	assert_eq(weapon["item_id"], "itm_iron_sword", "the stat item is never rewritten")
	assert_eq(int(weapon["item_count"]), 1, "count untouched")


# --- clearing + guards -------------------------------------------------------------------------


func test_clear_override_restores_the_real_item() -> void:
	var applied := _CO.apply_override(
		_equipped(), "weapon", "cos_gilded_blade", "#fff", ["cos_gilded_blade"]
	)
	var cleared := _CO.clear_override(applied["slots"], "weapon")
	assert_true(cleared["ok"])
	var weapon: Dictionary = _slot(cleared["slots"], "weapon")
	assert_false(weapon.has("appearance_override"), "override gone")
	assert_false(weapon.has("tint"), "tint gone")
	assert_eq(weapon["item_id"], "itm_iron_sword", "the real stat item is unchanged throughout")


func test_apply_rejects_non_gear_and_empty_slots() -> void:
	# bag is not a paper-doll slot.
	var bad_slot := _CO.apply_override(_equipped(), "bag", "cos_x", "", ["cos_x"])
	assert_false(bad_slot["ok"])
	assert_eq(bad_slot["reason"], "not_a_gear_slot")
	# legs is a valid gear slot but nothing is equipped there.
	var empty := _CO.apply_override(_equipped(), "legs", "cos_x", "", ["cos_x"])
	assert_false(empty["ok"])
	assert_eq(empty["reason"], "slot_empty")


# T-428: the complete wardrobe look is unlock-gated, slot-compatible, dye-validated, and contains
# presentation fields only. A forged stat-bearing appearance must fail closed before persistence.
func test_build_wardrobe_look_is_power_neutral_and_slot_validated() -> void:
	var appearance := {
		"id": "cos_gilded_blade",
		"display_item": "itm_iron_sword",
		"slot": "weapon",
		"armor_type": "none",
		"dye_mask": "all",
	}
	var dye := {"id": "dye_crimson", "color": "#9f3142"}
	var res := _CO.build_wardrobe_look(_equipped(), "weapon", appearance, dye, ["cos_gilded_blade"])
	assert_true(res["ok"])
	assert_eq(res["look"]["appearance_id"], "cos_gilded_blade")
	assert_eq(res["look"]["display_item"], "itm_iron_sword")
	assert_eq(res["look"]["dye_id"], "dye_crimson")
	assert_eq(res["look"]["dye_color"], "#9f3142")
	for forbidden in ["stats", "attack", "armor", "damage", "power"]:
		assert_false(res["look"].has(forbidden), "%s can never enter the look channel" % forbidden)
	var wrong_slot := _CO.build_wardrobe_look(
		_equipped(), "chest", appearance, dye, ["cos_gilded_blade"]
	)
	assert_false(wrong_slot["ok"])
	assert_eq(wrong_slot["reason"], "wrong_slot")


func test_build_wardrobe_look_rejects_forged_stats_and_unknown_dye() -> void:
	var forged := {
		"id": "cos_cheat",
		"display_item": "itm_iron_sword",
		"slot": "weapon",
		"stats": {"attack": 9999},
	}
	var denied := _CO.build_wardrobe_look(_equipped(), "weapon", forged, {}, ["cos_cheat"])
	assert_false(denied["ok"], "stat-bearing appearance definition is rejected")
	assert_eq(denied["reason"], "power_field")
	var appearance := {"id": "cos_ok", "display_item": "itm_iron_sword", "slot": "weapon"}
	var bad_dye := _CO.build_wardrobe_look(
		_equipped(), "weapon", appearance, {"id": "dye_forged", "color": "not-a-color"}, ["cos_ok"]
	)
	assert_false(bad_dye["ok"], "unauthored/invalid dye is rejected")
	assert_eq(bad_dye["reason"], "bad_dye")


func _slot(slots: Array, slot_type: String) -> Dictionary:
	for entry: Dictionary in slots:
		if str(entry["slot_type"]) == slot_type:
			return entry
	return {}
