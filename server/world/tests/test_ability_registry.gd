extends "res://addons/gut/test.gd"

# T-063: the ability registry loads the kit JSONs and filters by class.

const _AR = preload("res://scripts/combat/ability_registry.gd")
const _KIT = preload("res://scripts/kit_helper.gd")


func _reg():
	var r = _AR.new()
	r.load_from_dir("res://data/abilities")
	return r


func test_loads_all_ability_files() -> void:
	assert_true(_reg().count() >= 14, "loads strike + emberstrike + the 12 kits")


func test_get_abilities_for_class_sizes() -> void:
	var r = _reg()
	# T-365: +1 trainer-taught ability per class (cleave/scorch/greater_heal, banded L8).
	# T-434: Pummel + Concussive Blow round out the warrior control kit; Counterspell does
	# the same for mage, and Psychic Horror gives priest a hard-CC lever.
	assert_eq(r.get_abilities_for_class("warrior").size(), 7, "warrior kit includes kick + stun")
	assert_eq(r.get_abilities_for_class("mage").size(), 6, "mage kit includes Counterspell")
	# T-364: +1 priest ability (Resurrection, id 306) — the healer's field rez.
	assert_eq(r.get_abilities_for_class("priest").size(), 7, "priest kit includes hard CC")


func test_kit_sorted_and_class_tagged() -> void:
	var kit = _reg().get_abilities_for_class("warrior")
	assert_eq(kit[0].id, 101, "sorted by id — heroic_strike first")
	for ab in kit:
		assert_eq(ab.char_class, "warrior", "every kit ability is class-tagged")


func test_shared_basic_excluded_from_kits() -> void:
	var r = _reg()
	for cls in ["warrior", "mage", "priest"]:
		for ab in r.get_abilities_for_class(cls):
			assert_ne(ab.id, 1, "shared strike (auto-attack) is not in a class kit")


func test_effect_verbs_loaded_from_json() -> void:
	var r = _reg()
	assert_eq(r.get_ability(102).effect, "taunt")
	assert_eq(r.get_ability(203).effect, "control")
	assert_eq(r.get_ability(203).control_kind, "root")
	assert_eq(r.get_ability(301).effect, "heal")
	assert_true(r.get_ability(301).targets_friendly, "flash_heal targets friendly")


func test_control_toolkit_fields_load_and_rank() -> void:
	var r = _reg()
	var pummel = r.get_ability(106)
	assert_not_null(pummel, "Pummel is authored in the warrior kit")
	if pummel == null:
		return
	assert_true(pummel.can_full_interrupt, "Pummel is a purposeful full interrupt")
	assert_false(pummel.triggers_gcd, "interrupts are usable during the global cooldown")
	assert_gt(pummel.cooldown_ticks, 0, "Pummel carries its own server cooldown")
	assert_gt(pummel.school_lock_ticks, 0, "Pummel locks the interrupted spell school")
	var ranked = pummel.effective_at_level(12)
	assert_lt(ranked.cooldown_ticks, pummel.cooldown_ticks, "ranks shorten Pummel cooldown")
	assert_lte(ranked.resource_cost, pummel.resource_cost, "ranks do not increase Pummel cost")

	var warrior_cc = r.get_ability(107)
	var priest_cc = r.get_ability(307)
	assert_not_null(warrior_cc, "warrior hard CC is authored")
	assert_not_null(priest_cc, "priest hard CC is authored")
	if warrior_cc != null and priest_cc != null:
		assert_eq(warrior_cc.control_kind, "stun")
		assert_eq(priest_cc.control_kind, "stun")
		assert_eq(warrior_cc.control_dr_category, "stun")
		assert_eq(priest_cc.control_dr_category, "stun")


# T-524: authored rank ladders now span L13->40 (Era 2), not just the [1,6,12] Era-1 band.
# The rank cadence continues at L18/24/30/36/40 (final band 4 levels to hit the L40 cap).
func test_authored_ranks_scale_past_l12_to_l40() -> void:
	var r = _reg()
	# Representative damage / heal / interrupt abilities: fireball, flash_heal, pummel.
	var fireball = r.get_ability(201)
	var flash_heal = r.get_ability(301)
	var pummel = r.get_ability(106)
	assert_not_null(fireball, "fireball authored")
	assert_not_null(flash_heal, "flash_heal authored")
	assert_not_null(pummel, "pummel authored")
	if fireball == null or flash_heal == null or pummel == null:
		return
	# Every ladder reaches the L40 cap and picks a strictly higher rank than the old L12 top.
	assert_eq(fireball.rank_for_level(40), 8, "fireball ladder now has 8 ranks to the L40 cap")
	assert_gt(
		fireball.rank_for_level(40),
		fireball.rank_for_level(12),
		"rank keeps climbing past the old L12 ceiling"
	)
	# Damage grows smoothly across every new band — no flatline.
	var levels := [12, 18, 24, 30, 36, 40]
	for i in range(1, levels.size()):
		var prev := fireball.effective_at_level(levels[i - 1]).base_damage
		var cur := fireball.effective_at_level(levels[i]).base_damage
		assert_gt(cur, prev, "fireball dmg rises L%d->L%d" % [levels[i - 1], levels[i]])
		var prev_h := flash_heal.effective_at_level(levels[i - 1]).heal_base
		var cur_h := flash_heal.effective_at_level(levels[i]).heal_base
		assert_gt(cur_h, prev_h, "flash_heal grows L%d->L%d" % [levels[i - 1], levels[i]])
	# Interrupt power axis: school lock lengthens, cooldown shortens toward the cap.
	assert_gt(
		pummel.effective_at_level(40).school_lock_ticks,
		pummel.effective_at_level(12).school_lock_ticks,
		"pummel lock lengthens past L12"
	)
	assert_lt(
		pummel.effective_at_level(40).cooldown_ticks,
		pummel.effective_at_level(12).cooldown_ticks,
		"pummel cooldown shortens past L12"
	)


# T-524: the L1/6/12 breakpoints must be byte-identical after extending the ladder (no regression).
func test_old_breakpoints_unchanged_after_extension() -> void:
	var r = _reg()
	var fireball = r.get_ability(201)
	var flash_heal = r.get_ability(301)
	if fireball == null or flash_heal == null:
		return
	assert_eq(fireball.effective_at_level(1).base_damage, 30, "R1 dmg unchanged")
	assert_eq(fireball.effective_at_level(6).base_damage, 42, "R2 dmg unchanged")
	assert_eq(fireball.effective_at_level(12).base_damage, 58, "R3 dmg unchanged")
	assert_eq(flash_heal.effective_at_level(1).heal_base, 20, "R1 heal unchanged")
	assert_eq(flash_heal.effective_at_level(6).heal_base, 30, "R2 heal unchanged")
	assert_eq(flash_heal.effective_at_level(12).heal_base, 44, "R3 heal unchanged")
	# Bands 1/2/3 still unlock at L1/6/12.
	assert_eq(fireball.rank_for_level(6), 2, "R2 still unlocks at L6")
	assert_eq(fireball.rank_for_level(12), 3, "R3 still unlocks at L12")


func test_control_tools_flow_into_automatic_class_kit_payloads() -> void:
	var r = _reg()
	var expected := {"warrior": [106, 107], "mage": [206], "priest": [307]}
	for cls in expected:
		var kit: Array = _KIT.build_kit(r, cls, [])
		var by_id: Dictionary = {}
		for row in kit:
			by_id[int(row["id"])] = row
		for ability_id in expected[cls]:
			assert_true(by_id.has(ability_id), "%s kit auto-includes %d" % [cls, ability_id])
			assert_gt(int(by_id[ability_id]["cooldown_ticks"]), 0, "kit carries display cooldown")
