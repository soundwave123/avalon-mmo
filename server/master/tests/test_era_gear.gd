extends "res://addons/gut/test.gd"

# T-353: the pure era gear-carry re-scale (era-direction.md S4, Rule A). Proves the S4.3 truth table
# (epic->660, legendary->750 into Era 2, both strictly inside the (new-era rare, new-era epic)
# interval), the retire of common-through-rare, and the ONE-HOP guard (a carried relic does not
# re-scale a second time). No DB, no stack — the module is pure.

const EraGear = preload("res://scripts/era_gear.gd")

# A stand-in rarity map — item_id -> rarity (what the world injects from items.json).
const RARITIES := {
	"itm_common_mat": "common",
	"itm_rare_blade": "rare",
	"itm_epic_crown": "epic",
	"itm_legendary_edge": "legendary",
}


func _row(item_id: String, extra: Dictionary = {}) -> Dictionary:
	var row := {"slot_type": "bag", "slot_index": 0, "item_id": item_id, "item_count": 1}
	for k: String in extra:
		row[k] = extra[k]
	return row


# ---- era_band + rescaled_index: the S4.1/S4.3 numbers -------------------------------------------


func test_era_band_is_scale_to_the_era_minus_one() -> void:
	assert_eq(EraGear.era_band(1), 1)
	assert_eq(EraGear.era_band(2), 6)
	assert_eq(EraGear.era_band(3), 36)


func test_epic_rescales_to_660_into_era_2() -> void:
	assert_eq(EraGear.rescaled_index("epic", 2), 660)  # 100 * 6 * 1.10


func test_legendary_rescales_to_750_into_era_2() -> void:
	assert_eq(EraGear.rescaled_index("legendary", 2), 750)  # 100 * 6 * 1.25


func test_carried_piece_lands_strictly_between_new_era_rare_and_epic() -> void:
	var era2_rare := EraGear.RARITY_INDEX["rare"] * EraGear.era_band(2)  # 600
	var era2_epic := EraGear.RARITY_INDEX["epic"] * EraGear.era_band(2)  # 900
	for rarity: String in ["epic", "legendary"]:
		var landed := EraGear.rescaled_index(rarity, 2)
		assert_gt(landed, era2_rare, "%s must beat Era-2 rare (the rule reads true)" % rarity)
		assert_lt(landed, era2_epic, "%s must lose to Era-2 epic (the chase survives)" % rarity)


func test_rescale_holds_the_interval_at_the_next_era_too() -> void:
	var era3_rare := EraGear.RARITY_INDEX["rare"] * EraGear.era_band(3)  # 3600
	var era3_epic := EraGear.RARITY_INDEX["epic"] * EraGear.era_band(3)  # 5400
	assert_eq(EraGear.rescaled_index("epic", 3), 3960)
	assert_eq(EraGear.rescaled_index("legendary", 3), 4500)
	assert_gt(EraGear.rescaled_index("legendary", 3), era3_rare)
	assert_lt(EraGear.rescaled_index("legendary", 3), era3_epic)


func test_sub_epic_rarities_do_not_rescale() -> void:
	assert_eq(EraGear.rescaled_index("rare", 2), 0)
	assert_eq(EraGear.rescaled_index("common", 2), 0)


# ---- carry(): the transition matrix over a whole inventory --------------------------------------


func test_epic_carries_and_is_stamped() -> void:
	var out := EraGear.carry([_row("itm_epic_crown")], 2, RARITIES)
	var relic: Dictionary = out["slots"][0]
	assert_eq(relic["era_scaled_to"], 2)
	assert_eq(relic["era_index"], 660)
	assert_false(relic.has("retired"))
	assert_eq(out["carried"], ["itm_epic_crown"])
	assert_eq(out["retired"], [])


func test_legendary_carries_at_750() -> void:
	var out := EraGear.carry([_row("itm_legendary_edge")], 2, RARITIES)
	assert_eq(out["slots"][0]["era_index"], 750)
	assert_eq(out["carried"], ["itm_legendary_edge"])


func test_rare_is_retired_not_carried() -> void:
	var out := EraGear.carry([_row("itm_rare_blade")], 2, RARITIES)
	var blade: Dictionary = out["slots"][0]
	assert_true(blade["retired"])
	assert_false(blade.has("era_scaled_to"))
	assert_eq(out["retired"], ["itm_rare_blade"])
	assert_eq(out["carried"], [])


func test_common_is_retired() -> void:
	var out := EraGear.carry([_row("itm_common_mat")], 2, RARITIES)
	assert_true(out["slots"][0]["retired"])
	assert_eq(out["retired"], ["itm_common_mat"])


func test_double_crossing_does_not_double_scale() -> void:
	# A relic already stamped era_scaled_to (carried into Era 2) hits the Era-2->3 rift: one hop, so
	# it does NOT re-scale again — it retires with everything else sub-epic (S4.3).
	var carried_relic := _row("itm_epic_crown", {"era_scaled_to": 2, "era_index": 660})
	var out := EraGear.carry([carried_relic], 3, RARITIES)
	var relic: Dictionary = out["slots"][0]
	assert_eq(relic["era_scaled_to"], 2, "the stamp is not overwritten")
	assert_eq(relic["era_index"], 660, "power is NOT re-scaled a second time")
	assert_true(relic["retired"], "a spent relic retires at the next rift")
	assert_eq(out["carried"], [])
	assert_eq(out["retired"], ["itm_epic_crown"])


func test_native_next_era_epic_still_carries_once() -> void:
	# An epic looted natively in Era 2 (no stamp) DOES carry at the Era-2->3 rift — one hop from
	# where it currently lives (S4.3: "only epics/legendaries you hold as Era-2 items cross to 3").
	var out := EraGear.carry([_row("itm_epic_crown")], 3, RARITIES)
	assert_eq(out["slots"][0]["era_scaled_to"], 3)
	assert_eq(out["slots"][0]["era_index"], 3960)
	assert_eq(out["carried"], ["itm_epic_crown"])


func test_mixed_bag_splits_carry_from_retire() -> void:
	var bag := [
		_row("itm_common_mat"),
		_row("itm_rare_blade"),
		_row("itm_epic_crown"),
		_row("itm_legendary_edge"),
	]
	var out := EraGear.carry(bag, 2, RARITIES)
	assert_eq((out["carried"] as Array).size(), 2)
	assert_eq((out["retired"] as Array).size(), 2)


func test_input_slots_are_never_mutated() -> void:
	var original := _row("itm_epic_crown")
	EraGear.carry([original], 2, RARITIES)
	assert_false(original.has("era_scaled_to"), "carry works on a deep copy")
	assert_false(original.has("retired"))


func test_unknown_item_id_is_retired_not_crashed() -> void:
	var out := EraGear.carry([_row("itm_mystery")], 2, RARITIES)
	assert_true(out["slots"][0]["retired"])
