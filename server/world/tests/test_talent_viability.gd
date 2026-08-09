# T-474: off-spec viability bar — deterministic arithmetic over the REAL shipped data
# (data/talents/*.json + data/abilities/*.json + master's class_growth.json) proving the
# T-435 "+ Hybrid" pillar: each off-spec clears its content band instead of being a trap.
#
# Model (no RNG, no variance — expected values on both sides so ratios are exact):
#   damage(ability) = (rank base_damage at L12 + sum stat*coeff) * talent damage multiplier
#   dps             = damage / max(cast_ticks, GCD_TICKS) seconds
#   threat          = damage * threat_multiplier (+ flat threat_amount abilities)
#   ehp             = StatConverter.max_hp(stamina)
#
# Viability bars (the ticket's "viable off-spec" measure, tuned to the L12 band):
#   Protection warrior: EHP >= 1.15x Arms; threat/s >= reference DPS (fire mage) so the
#     tank holds aggro; solo damage >= 60% of Arms (leveling is not a trap).
#   Shadow priest: sustained DPS >= 70% of the fire mage (the pure-DPS reference).
#   Utility (arcane) mage: DPS >= 85% of fire; Frost Nova cost cut >= 25% (control on
#     demand); full-kit basket (fireball+fire_blast+frost_nova) cheaper than under fire.
# A data regression that drops an off-spec below its band fails here.

extends GutTest

const _TEF = preload("res://scripts/combat/talent_effects.gd")
const _SCV = preload("res://scripts/combat/stat_converter.gd")
const _SC = preload("res://scripts/server_config.gd")
const _REG = preload("res://scripts/content/content_registry.gd")

const _LEVEL := 12  # top of the shipped ability-rank band (ranks stop at min_level 12)

# T-523: L60-cap tree-shape constants. Budgets mirror master talent_logic
# points_available(level) = level - 1 (T-035 grant); gate mirrors POINTS_PER_TIER.
const _BUDGET_L40 := 39
const _BUDGET_L60 := 59
const _POINTS_PER_TIER := 5
const _CAPSTONE_TIER := 7

# 11 points at L12 (1/level from L2) — every build below must be greedily spendable.
const _BUILDS := {
	"warrior_arms":
	{
		"tal_war_might": 3,
		"tal_war_imp_heroic": 3,
		"tal_war_tactics": 1,
		"tal_war_deep_wounds": 3,
		"tal_war_executioner": 1,
	},
	"warrior_prot":
	{
		"tal_war_shield_wall": 3,
		"tal_war_imp_taunt": 2,
		"tal_war_imp_sunder": 3,
		"tal_war_vengeance": 3,
	},
	"priest_shadow":
	{
		"tal_pri_imp_smite": 3,
		"tal_pri_darkness": 3,
		"tal_pri_shadow_focus": 3,
		"tal_pri_mind_flay": 2,
	},
	"mage_fire":
	{
		"tal_mag_imp_fireball": 3,
		"tal_mag_burning_mind": 3,
		"tal_mag_ignite": 3,
		"tal_mag_pyromania": 2,
	},
	"mage_arcane":
	{
		"tal_mag_arcane_mind": 3,
		"tal_mag_meditation": 2,
		"tal_mag_clarity": 3,
		"tal_mag_arcane_power": 2,
		"tal_mag_presence": 1,
	},
}

var _defs: Dictionary = {}
var _trees: Dictionary = {}  # class -> Array of {id, role}
var _growth: Dictionary = {}


func before_all() -> void:
	for cls in ["warrior", "mage", "priest"]:
		var parsed: Dictionary = _load_json("res://data/talents/%s.json" % cls)
		_trees[cls] = parsed.get("trees", [])
		for tal in parsed.get("talents", []):
			_defs[str(tal.get("id", ""))] = tal
	var growth_path := ProjectSettings.globalize_path("res://").path_join(
		"../master/data/class_growth.json"
	)
	_growth = _load_json(growth_path)


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	assert_not_null(f, "readable: %s" % path)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	assert_true(parsed is Dictionary, "valid JSON object: %s" % path)
	return parsed if parsed is Dictionary else {}


# L12 stat vector for a class: growth base + per_level * (L-1), then talent stat_adds.
func _stats(cls: String, build: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var base: Dictionary = _growth.get("base", {})
	var per: Dictionary = _growth.get("per_level", {}).get(cls, {})
	for stat in base:
		out[stat] = int(base[stat]) + int(per.get(stat, 0)) * (_LEVEL - 1)
	for talent_id in build:
		var effect: Dictionary = _defs.get(talent_id, {}).get("effect", {})
		if str(effect.get("kind", "")) == "stat_add":
			var stat := str(effect.get("stat", ""))
			out[stat] = (
				int(out.get(stat, 0)) + int(effect.get("per_rank", 0)) * int(build[talent_id])
			)
	return out


# Ability def with the L12 rank folded in (highest min_level <= L12 wins).
func _ability(fname: String) -> Dictionary:
	var ab: Dictionary = _load_json("res://data/abilities/%s.json" % fname)
	var best_level := -1
	for rank in ab.get("ranks", []):
		var min_level := int(rank.get("min_level", 1))
		if min_level <= _LEVEL and min_level > best_level:
			best_level = min_level
			for key in rank:
				ab[key] = rank[key]
	return ab


func _expected_damage(ab: Dictionary, stats: Dictionary, mods: Dictionary) -> float:
	var raw := float(ab.get("base_damage", 0))
	var coeffs: Dictionary = ab.get("attacker_stat_coeffs", {})
	for stat in coeffs:
		raw += float(stats.get(stat, 0)) * float(coeffs[stat])
	return raw * _TEF.damage_multiplier(mods, int(ab.get("id", 0)))


func _cast_sec(ab: Dictionary) -> float:
	return float(maxi(int(ab.get("cast_ticks", 0)), _SC.GCD_TICKS)) / float(_SC.TICK_RATE_HZ)


func _dps(ab: Dictionary, stats: Dictionary, mods: Dictionary) -> float:
	return _expected_damage(ab, stats, mods) / _cast_sec(ab)


func _cost(ab: Dictionary, mods: Dictionary) -> float:
	var base := float(ab.get("mana_cost", ab.get("resource_cost", 0)))
	return base * _TEF.cost_multiplier(mods, int(ab.get("id", 0)))


# --- the trees validate fail-loud through the T-064 loader rules ---


func test_talent_data_validates() -> void:
	var errors: Array = _REG.validate_talents(_defs, _REG._ability_ids("res://data/abilities"))
	assert_eq(errors, [], "talent data must validate clean: %s" % str(errors))


# --- schema bar: every class exposes >= 2 role-distinct trees, and roles cover the data ---


func test_each_class_exposes_role_distinct_trees() -> void:
	for cls in _trees:
		var roles: Dictionary = {}
		var declared: Dictionary = {}
		for tree in _trees[cls]:
			roles[str(tree.get("role", ""))] = true
			declared[str(tree.get("id", ""))] = true
		assert_gte(roles.size(), 2, "%s trees must span >= 2 distinct roles" % cls)
	for talent_id in _defs:
		var tal: Dictionary = _defs[talent_id]
		var found := false
		for tree in _trees.get(str(tal.get("class", "")), []):
			if str(tree.get("id", "")) == str(tal.get("tree", "")):
				found = true
		assert_true(found, "talent %s tree is declared in trees metadata" % talent_id)


# --- expressibility: every build is spendable under the real T-064 rules at L12 ---


func test_offspec_builds_are_spendable_at_level_12() -> void:
	for build_name in _BUILDS:
		var build: Dictionary = _BUILDS[build_name]
		var spent := _greedy_spend(build)
		for talent_id in build:
			assert_eq(
				int(spent.get(talent_id, 0)),
				int(build[talent_id]),
				"%s: %s fully spendable" % [build_name, talent_id]
			)


# Re-encodes the T-064 spend gates (budget, max_ranks, tier gate, prereq maxed) as an
# independent oracle: spend one legal point at a time until stuck.
func _greedy_spend(build: Dictionary, budget: int = _LEVEL - 1) -> Dictionary:
	var spent: Dictionary = {}
	var progressed := true
	while progressed and _total(spent) < budget:
		progressed = false
		for talent_id in build:
			if _total(spent) >= budget:
				break
			var tal: Dictionary = _defs.get(talent_id, {})
			if (
				int(spent.get(talent_id, 0))
				>= mini(int(build[talent_id]), int(tal.get("max_ranks", 1)))
			):
				continue
			# T-523: POINTS_PER_TIER is 5 (mirror of master talent_logic — the L60-cap shape).
			if _tree_points(spent, str(tal.get("tree", ""))) < (int(tal.get("tier", 1)) - 1) * 5:
				continue
			var prereq = tal.get("prereq")
			if prereq != null and str(prereq) != "":
				var need := int(_defs.get(str(prereq), {}).get("max_ranks", 1))
				if int(spent.get(str(prereq), 0)) < need:
					continue
			spent[talent_id] = int(spent.get(talent_id, 0)) + 1
			progressed = true
	return spent


func _total(spent: Dictionary) -> int:
	var total := 0
	for talent_id in spent:
		total += int(spent[talent_id])
	return total


func _tree_points(spent: Dictionary, tree: String) -> int:
	var total := 0
	for talent_id in spent:
		if str(_defs.get(talent_id, {}).get("tree", "")) == tree:
			total += int(spent[talent_id])
	return total


# --- viability bars ---


func test_protection_warrior_offspec_is_viable() -> void:
	var arms: Dictionary = _BUILDS["warrior_arms"]
	var prot: Dictionary = _BUILDS["warrior_prot"]
	var arms_stats := _stats("warrior", arms)
	var prot_stats := _stats("warrior", prot)
	var arms_mods: Dictionary = _TEF.ability_mods(arms, _defs)
	var prot_mods: Dictionary = _TEF.ability_mods(prot, _defs)
	var heroic := _ability("heroic_strike")
	var revenge := _ability("revenge")
	var sunder := _ability("sunder_armor")

	# Survivability: the tank build banks meaningfully more EHP than the DPS build.
	var arms_hp := float(_SCV.max_hp(int(arms_stats["stamina"])))
	var prot_hp := float(_SCV.max_hp(int(prot_stats["stamina"])))
	assert_gte(prot_hp, arms_hp * 1.15, "prot EHP >= 115%% of arms (%f vs %f)" % [prot_hp, arms_hp])

	# Threat: revenge + sunder alternated on the GCD outpaces the reference DPS (fire mage),
	# so an off-spec-built warrior actually holds aggro against a pure damage dealer.
	var revenge_threat := (
		_expected_damage(revenge, prot_stats, prot_mods)
		* float(revenge.get("threat_multiplier", 1.0))
	)
	var cycle_sec := 2.0 * float(_SC.GCD_TICKS) / float(_SC.TICK_RATE_HZ)
	var prot_tps := (revenge_threat + float(sunder.get("threat_amount", 0))) / cycle_sec
	var mage_dps := _reference_mage_dps()
	assert_gte(prot_tps, mage_dps, "prot threat/s >= mage DPS (%f vs %f)" % [prot_tps, mage_dps])

	# Not a leveling trap: the prot warrior's untalented main strike still lands >= 60% of the
	# fully-talented arms strike.
	var prot_hit := _expected_damage(heroic, prot_stats, {})
	var arms_hit := _expected_damage(heroic, arms_stats, arms_mods)
	assert_gte(
		prot_hit, arms_hit * 0.60, "prot solo hit >= 60%% of arms (%f vs %f)" % [prot_hit, arms_hit]
	)


func test_shadow_priest_offspec_dps_band() -> void:
	var build: Dictionary = _BUILDS["priest_shadow"]
	var stats := _stats("priest", build)
	var mods: Dictionary = _TEF.ability_mods(build, _defs)
	var shadow_dps := _dps(_ability("smite"), stats, mods)
	var mage_dps := _reference_mage_dps()
	assert_gte(
		shadow_dps,
		mage_dps * 0.70,
		"shadow priest DPS >= 70%% of the fire mage (%f vs %f)" % [shadow_dps, mage_dps]
	)


func test_utility_mage_offspec_is_viable() -> void:
	var arcane: Dictionary = _BUILDS["mage_arcane"]
	var stats := _stats("mage", arcane)
	var arcane_mods: Dictionary = _TEF.ability_mods(arcane, _defs)
	var fire_mods: Dictionary = _TEF.ability_mods(_BUILDS["mage_fire"], _defs)
	var fireball := _ability("fireball")
	var blast := _ability("fire_blast")
	var nova := _ability("frost_nova")

	# Throughput stays in band vs the pure-DPS spec.
	var arcane_dps := _dps(fireball, stats, arcane_mods)
	var fire_dps := _reference_mage_dps()
	assert_gte(
		arcane_dps,
		fire_dps * 0.85,
		"arcane DPS >= 85%% of fire (%f vs %f)" % [arcane_dps, fire_dps]
	)

	# Control on demand: the utility branch cuts Frost Nova's cost by at least a quarter.
	var nova_mult: float = _TEF.cost_multiplier(arcane_mods, int(nova.get("id", 0)))
	assert_lte(nova_mult, 0.75, "arcane cuts Frost Nova cost >= 25%% (mult %f)" % nova_mult)

	# Whole-kit efficiency: the fireball+blast+nova basket is cheaper under arcane than under
	# fire's single-spell discount — the utility identity is breadth, not one nuke.
	var arcane_basket := (
		_cost(fireball, arcane_mods) + _cost(blast, arcane_mods) + _cost(nova, arcane_mods)
	)
	var fire_basket := _cost(fireball, fire_mods) + _cost(blast, fire_mods) + _cost(nova, fire_mods)
	assert_lt(
		arcane_basket,
		fire_basket,
		"arcane basket cost < fire (%f vs %f)" % [arcane_basket, fire_basket]
	)


# --- T-523: L60-cap tree shape — points << capacity, deep-gated capstones ------------------


func _class_capacity(cls: String) -> int:
	var total := 0
	for talent_id in _defs:
		if str(_defs[talent_id].get("class", "")) == cls:
			total += int(_defs[talent_id].get("max_ranks", 0))
	return total


func _tree_capacity(cls: String, tree: String) -> int:
	var total := 0
	for talent_id in _defs:
		var tal: Dictionary = _defs[talent_id]
		if str(tal.get("class", "")) == cls and str(tal.get("tree", "")) == tree:
			total += int(tal.get("max_ranks", 0))
	return total


# (a) At BOTH caps the point budget is far below total capacity: choices stay real, and no
# pair of trees can be simultaneously maxed (so at most ~one tree is ever completed).
func test_budget_far_below_capacity_at_both_caps() -> void:
	for cls in _trees:
		var capacity := _class_capacity(cls)
		assert_gte(
			float(capacity),
			2.5 * _BUDGET_L60,
			"%s capacity %d >= 2.5x the L60 budget" % [cls, capacity]
		)
		assert_gte(
			float(capacity),
			2.5 * _BUDGET_L40,
			"%s capacity %d >= 2.5x the L40 budget" % [cls, capacity]
		)
		var tree_ids: Array = _trees[cls]
		for i in tree_ids.size():
			for j in range(i + 1, tree_ids.size()):
				var pair := (
					_tree_capacity(cls, str(tree_ids[i].get("id", "")))
					+ _tree_capacity(cls, str(tree_ids[j].get("id", "")))
				)
				assert_gt(pair, _BUDGET_L60, "%s: no two trees can both be maxed at L60" % cls)


# (b) Every tree bottoms out in exactly ONE 1-rank capstone at tier 7, whose in-tree gate
# (30 points) costs a majority of the budget — a capstone is a spec commitment, and even
# two capstones (2 x 31 points) exceed the L60 budget.
func test_each_tree_has_one_deep_gated_capstone() -> void:
	var gate := (_CAPSTONE_TIER - 1) * _POINTS_PER_TIER
	assert_gt(2 * (gate + 1), _BUDGET_L60, "two capstones must not fit in the L60 budget")
	assert_gt(gate, _BUDGET_L40 / 2, "the capstone gate is a majority of the L40 budget")
	for cls in _trees:
		for tree in _trees[cls]:
			var tree_id := str(tree.get("id", ""))
			var capstones: Array = []
			for talent_id in _defs:
				var tal: Dictionary = _defs[talent_id]
				if (
					str(tal.get("class", "")) == cls
					and str(tal.get("tree", "")) == tree_id
					and int(tal.get("tier", 0)) == _CAPSTONE_TIER
					and int(tal.get("max_ranks", 0)) == 1
				):
					capstones.append(talent_id)
			assert_eq(capstones.size(), 1, "%s/%s has exactly one 1-rank capstone" % [cls, tree_id])


# (c) Tier gating at depth: a deep single-tree build reaches its capstone at the L40 budget
# (39 >= 30 + 1) but NOT with only 30 points (the gate consumes them all) — proved through
# the same greedy oracle that re-encodes the T-064 spend rules.
func test_capstone_reachable_only_by_deep_investment() -> void:
	for cls in _trees:
		for tree in _trees[cls]:
			var tree_id := str(tree.get("id", ""))
			var build := _deep_tree_build(cls, tree_id)
			var capstone := _capstone_of(cls, tree_id)
			var deep := _greedy_spend(build, _BUDGET_L40)
			assert_eq(
				int(deep.get(capstone, 0)),
				1,
				"%s/%s capstone reachable with the L40 budget" % [cls, tree_id]
			)
			var shallow := _greedy_spend(build, (_CAPSTONE_TIER - 1) * _POINTS_PER_TIER)
			assert_eq(
				int(shallow.get(capstone, 0)),
				0,
				"%s/%s capstone unreachable on 30 points (gate eats them)" % [cls, tree_id]
			)


func _capstone_of(cls: String, tree_id: String) -> String:
	for talent_id in _defs:
		var tal: Dictionary = _defs[talent_id]
		if (
			str(tal.get("class", "")) == cls
			and str(tal.get("tree", "")) == tree_id
			and int(tal.get("tier", 0)) == _CAPSTONE_TIER
			and int(tal.get("max_ranks", 0)) == 1
		):
			return talent_id
	return ""


# A tier-ordered single-tree build: whole talents (a prereq'd talent only once its prereq
# is already in the path, at max) until the lower tiers hold the capstone gate's 30 points.
func _deep_tree_build(cls: String, tree_id: String) -> Dictionary:
	var pool: Array = []
	for talent_id in _defs:
		var tal: Dictionary = _defs[talent_id]
		if str(tal.get("class", "")) != cls or str(tal.get("tree", "")) != tree_id:
			continue
		if int(tal.get("tier", 0)) < _CAPSTONE_TIER:
			pool.append(talent_id)
	pool.sort_custom(func(a, b): return int(_defs[a].get("tier", 0)) < int(_defs[b].get("tier", 0)))
	var build: Dictionary = {}
	var banked := 0
	for talent_id in pool:
		if banked >= (_CAPSTONE_TIER - 1) * _POINTS_PER_TIER:
			break
		var prereq = _defs[talent_id].get("prereq")
		if prereq != null and str(prereq) != "" and not build.has(str(prereq)):
			continue
		build[talent_id] = int(_defs[talent_id].get("max_ranks", 1))
		banked += int(build[talent_id])
	build[_capstone_of(cls, tree_id)] = 1
	return build


# The pure-DPS reference every off-spec band is measured against: the talented fire mage.
func _reference_mage_dps() -> float:
	var build: Dictionary = _BUILDS["mage_fire"]
	return _dps(_ability("fireball"), _stats("mage", build), _TEF.ability_mods(build, _defs))
