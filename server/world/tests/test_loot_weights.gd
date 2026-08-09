# T-232: rarity-weighted loot roll — tier weights respected within tolerance, legacy
# flat-loot mobs keep working (additive change), and the real data file loads clean.

extends GutTest

const _LOOT = preload("res://scripts/combat/loot_table.gd")

# One loot entry per rarity tier, chance 1.0, so a picked tier always has exactly one match —
# isolates the tier-weighting math from the legacy per-item chance/count roll.
const _ALL_TIER_LOOT := [
	{"item_id": "itm_junk", "chance": 1.0, "count_min": 1, "count_max": 1},
	{"item_id": "itm_common", "chance": 1.0, "count_min": 1, "count_max": 1},
	{"item_id": "itm_uncommon", "chance": 1.0, "count_min": 1, "count_max": 1},
	{"item_id": "itm_rare", "chance": 1.0, "count_min": 1, "count_max": 1},
	{"item_id": "itm_epic", "chance": 1.0, "count_min": 1, "count_max": 1},
	{"item_id": "itm_legendary", "chance": 1.0, "count_min": 1, "count_max": 1},
]
const _ALL_TIER_RARITIES := {
	"itm_junk": "junk",
	"itm_common": "common",
	"itm_uncommon": "uncommon",
	"itm_rare": "rare",
	"itm_epic": "epic",
	"itm_legendary": "legendary",
}

# Mirrors data/loot/rarity_weights.json difficulty "2" row (see the Done block tuning table).
const _DIFF2_WEIGHTS := {
	"2": {"junk": 2, "common": 78, "uncommon": 17, "rare": 3, "epic": 0, "legendary": 0}
}


func _rng(seed_val: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_val
	return r


# Fixed-seed roll respects the weight table within tolerance over N rolls.
func test_weighted_roll_respects_tier_distribution() -> void:
	var counts := {"junk": 0, "common": 0, "uncommon": 0, "rare": 0, "epic": 0, "legendary": 0}
	var n := 4000
	for i in range(n):
		var out := _LOOT.roll_weighted(
			_ALL_TIER_LOOT, _ALL_TIER_RARITIES, _DIFF2_WEIGHTS, 2, _rng(1000 + i)
		)
		assert_eq(out.size(), 1, "exactly one tier-matching entry always drops")
		var item_id: String = str(out[0]["item"])
		var rarity: String = str(_ALL_TIER_RARITIES[item_id])
		counts[rarity] += 1

	# Tolerance: +/- 5 percentage points of N (generous vs. binomial sigma at this N).
	var tolerance := int(n * 0.05)
	assert_between(counts["junk"], int(n * 0.02) - tolerance, int(n * 0.02) + tolerance)
	assert_between(counts["common"], int(n * 0.78) - tolerance, int(n * 0.78) + tolerance)
	assert_between(counts["uncommon"], int(n * 0.17) - tolerance, int(n * 0.17) + tolerance)
	assert_between(counts["rare"], int(n * 0.03) - tolerance, int(n * 0.03) + tolerance)
	assert_eq(counts["epic"], 0, "difficulty 2 has zero weight on epic")
	assert_eq(counts["legendary"], 0, "difficulty 2 has zero weight on legendary")


# A mob whose loot entries aren't in the item-rarity registry falls back to the legacy flat
# roll (additive change — no regression for un-migrated data).
func test_legacy_flat_loot_still_drops_without_rarity_data() -> void:
	var loot := [{"item_id": "itm_wolf_pelt", "chance": 1.0, "count_min": 1, "count_max": 1}]
	for i in range(10):
		var out := _LOOT.roll_weighted(loot, {}, _DIFF2_WEIGHTS, 2, _rng(i))
		assert_eq(out.size(), 1, "legacy loot must still drop with an empty rarity registry")
		assert_eq(out[0]["item"], "itm_wolf_pelt")


# Same fallback when the weight table itself is missing/empty (e.g. malformed data file).
func test_missing_weight_table_falls_back_to_legacy_roll() -> void:
	var loot := [{"item_id": "itm_wolf_pelt", "chance": 1.0}]
	var out := _LOOT.roll_weighted(loot, _ALL_TIER_RARITIES, {}, 2, _rng(1))
	assert_eq(out.size(), 1)
	assert_eq(out[0]["item"], "itm_wolf_pelt")


# Difficulty with no row in the weight table (e.g. 99) also falls back rather than dropping
# nothing.
func test_unknown_difficulty_falls_back_to_legacy_roll() -> void:
	var loot := [{"item_id": "itm_wolf_pelt", "chance": 1.0}]
	var out := _LOOT.roll_weighted(loot, _ALL_TIER_RARITIES, _DIFF2_WEIGHTS, 99, _rng(1))
	assert_eq(out.size(), 1)


# A kill can land zero drops when the mob has no loot at the rolled tier — the miss IS the
# variable-ratio schedule. Force an always-epic pick against a mob with no epic loot.
func test_tier_miss_yields_no_drop() -> void:
	var loot := [{"item_id": "itm_common", "chance": 1.0}]
	var rarities := {"itm_common": "common"}
	var epic_only_weights := {"3": {"epic": 1}}
	var out := _LOOT.roll_weighted(loot, rarities, epic_only_weights, 3, _rng(5))
	assert_eq(out.size(), 0, "rolled tier has no matching loot -> no drop, not a fallback")


# The real data file parses and has a row per difficulty 1-5.
func test_real_rarity_weights_file_loads() -> void:
	var weights := _LOOT.load_rarity_weights()
	assert_false(weights.is_empty(), "data/loot/rarity_weights.json must load")
	for difficulty in range(1, 6):
		var row: Dictionary = weights.get(str(difficulty), {})
		assert_false(row.is_empty(), "missing weight row for difficulty %d" % difficulty)


func test_missing_file_returns_empty_dict() -> void:
	assert_eq(_LOOT.load_rarity_weights("res://data/loot/does_not_exist.json"), {})
