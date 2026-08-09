# T-064: pure talent spend validation + stat mods.

extends GutTest

const _TL = preload("res://scripts/talent_logic.gd")

var _defs := {
	"tal_a":
	{
		"id": "tal_a",
		"class": "mage",
		"tree": "fire",
		"tier": 1,
		"max_ranks": 3,
		"prereq": null,
		"effect": {"kind": "ability_damage_pct", "ability_id": 201, "pct_per_rank": 5},
	},
	"tal_b":
	{
		"id": "tal_b",
		"class": "mage",
		"tree": "fire",
		"tier": 2,
		"max_ranks": 2,
		"prereq": "tal_a",
		"effect": {"kind": "ability_cost_pct", "ability_id": 201, "pct_per_rank": 10},
	},
	"tal_c":
	{
		"id": "tal_c",
		"class": "mage",
		"tree": "arcane",
		"tier": 1,
		"max_ranks": 3,
		"prereq": null,
		"effect": {"kind": "stat_add", "stat": "int", "per_rank": 2},
	},
	# T-523: a second tier-1 fire talent so the tier-2 gate (now 5 points in tree) can be
	# met without maxing tal_a — lets the prereq check be exercised separately from the gate.
	"tal_d":
	{
		"id": "tal_d",
		"class": "mage",
		"tree": "fire",
		"tier": 1,
		"max_ranks": 5,
		"prereq": null,
		"effect": {"kind": "stat_add", "stat": "spirit", "per_rank": 1},
	},
}


func test_points_economy() -> void:
	assert_eq(_TL.points_available(1), 0, "L1 has no points")
	assert_eq(_TL.points_available(5), 4, "1 point per level from L2")
	assert_eq(_TL.points_spent({"tal_a": 2, "tal_c": 1}), 3)
	assert_eq(_TL.points_in_tree({"tal_a": 2, "tal_c": 1}, _defs, "fire"), 2)


func test_spend_ok_and_wrong_class() -> void:
	assert_true(_TL.validate_spend(_defs["tal_a"], {}, _defs, "mage", 2)["ok"])
	var r: Dictionary = _TL.validate_spend(_defs["tal_a"], {}, _defs, "warrior", 2)
	assert_false(r["ok"])
	assert_eq(r["reason"], "wrong_class")


func test_spend_rejects_when_out_of_points() -> void:
	var r: Dictionary = _TL.validate_spend(_defs["tal_a"], {"tal_c": 1}, _defs, "mage", 2)
	assert_false(r["ok"], "L2 has exactly 1 point; it is spent")
	assert_eq(r["reason"], "no_points")


func test_spend_rejects_over_max_ranks() -> void:
	var r: Dictionary = _TL.validate_spend(_defs["tal_a"], {"tal_a": 3}, _defs, "mage", 9)
	assert_false(r["ok"])
	assert_eq(r["reason"], "max_ranks")


func test_tier_gate_requires_points_in_tree() -> void:
	# T-523: tier 2 needs POINTS_PER_TIER (5) points already in the SAME tree.
	var locked: Dictionary = _TL.validate_spend(_defs["tal_b"], {"tal_a": 3}, _defs, "mage", 9)
	assert_false(locked["ok"])
	assert_eq(locked["reason"], "tier_locked")
	# points in ANOTHER tree don't unlock it
	var other: Dictionary = _TL.validate_spend(
		_defs["tal_b"], {"tal_c": 3, "tal_a": 1}, _defs, "mage", 9
	)
	assert_false(other["ok"], "arcane points must not unlock the fire tier gate")


func test_prereq_requires_max_ranks() -> void:
	# T-523: 5 fire points (tier-2 gate met) but tal_a below its 3-rank max -> prereq gate.
	var unmet: Dictionary = _TL.validate_spend(
		_defs["tal_b"], {"tal_a": 2, "tal_d": 3}, _defs, "mage", 9
	)
	assert_false(unmet["ok"])
	assert_eq(unmet["reason"], "prereq_unmet")
	var met: Dictionary = _TL.validate_spend(
		_defs["tal_b"], {"tal_a": 3, "tal_d": 2}, _defs, "mage", 9
	)
	assert_true(met["ok"], "prereq at max ranks + tier satisfied (5 pts in fire)")


func test_apply_stat_mods_adds_per_rank() -> void:
	var stats := {"str": 10, "int": 15}
	var out: Dictionary = _TL.apply_stat_mods(stats, {"tal_c": 2}, _defs)
	assert_eq(int(out["int"]), 19, "+2 int per rank x2")
	assert_eq(int(out["str"]), 10, "untouched stats unchanged")
	assert_eq(int(stats["int"]), 15, "input never mutated")


# ---- T-475/T-525: the reroll coin-sink cost curve ----


func test_reroll_cost_doubles_from_base_and_caps() -> void:
	assert_eq(_TL.reroll_cost(0), 150, "first correction is cheap (one mid-band quest)")
	assert_eq(_TL.reroll_cost(1), 300)
	assert_eq(_TL.reroll_cost(2), 600)
	assert_eq(_TL.reroll_cost(3), 1000, "150*2^3=1200 capped at 1000")
	assert_eq(_TL.reroll_cost(50), 1000, "deep counters stay at the cap (no overflow)")
	assert_eq(_TL.reroll_cost(-3), 150, "a corrupt negative counter prices as the first")
