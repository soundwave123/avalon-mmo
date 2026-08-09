extends "res://addons/gut/test.gd"

# T-062: pure class-resource model. Clock-injected, deterministic — advance ticks, never sleep.

const RM = preload("res://scripts/combat/resource_model.gd")
const STC = preload("res://scripts/combat/stat_converter.gd")

# ---- Rage generation ----


func test_rage_builds_from_damage_dealt() -> void:
	assert_eq(RM.rage_on_damage_dealt(0, 20), 10, "20 dmg * 0.5 = 10 rage")
	assert_gt(RM.rage_on_damage_dealt(10, 20), 10, "rage accumulates")


func test_rage_builds_from_damage_taken() -> void:
	assert_eq(RM.rage_on_damage_taken(0, 20), 10, "taking 20 dmg builds 10 rage")


func test_rage_clamps_at_max() -> void:
	assert_eq(RM.rage_on_damage_dealt(95, 100), RM.RAGE_MAX, "rage never exceeds 100")


func test_rage_negative_damage_is_noop() -> void:
	assert_eq(RM.rage_on_damage_dealt(30, -5), 30, "negative damage adds no rage")


# ---- Rage decay (out of combat only) ----


func test_rage_holds_while_in_combat() -> void:
	# now within out_of_combat window of last combat → no decay even on a decay-interval tick.
	var out_ticks := 60
	assert_eq(RM.decay_rage(50, 100, 100, out_ticks), 50, "in combat (now==last) → rage holds")


func test_rage_decays_out_of_combat() -> void:
	var out_ticks := 60
	# last combat at tick 0, now=200 (> 60 since combat) and 200 % 10 == 0 → one decay step.
	assert_eq(RM.decay_rage(50, 0, 200, out_ticks), 50 - RM.RAGE_DECAY_PER_INTERVAL, "decays OOC")


func test_rage_decay_only_on_interval() -> void:
	var out_ticks := 60
	assert_eq(RM.decay_rage(50, 0, 205, out_ticks), 50, "no decay off the decay interval")


func test_rage_decay_floors_at_zero() -> void:
	assert_eq(RM.decay_rage(1, 0, 200, 60), 0, "rage decay never goes negative")


# ---- Mana regen + the 5-second rule ----


func test_mana_no_regen_off_interval() -> void:
	assert_eq(RM.regen_mana(50, 100, 0, 31, 40), 50, "no regen except on the regen interval")


func test_mana_base_regen_within_five_second_rule() -> void:
	# spent at tick 0, now=30 (< 100 ticks since spend) → only the flat base regen, NOT Spirit regen.
	var now := RM.MANA_REGEN_INTERVAL_TICKS  # 30 — on the interval, inside the 5s window
	assert_eq(
		RM.regen_mana(50, 100, 0, now, 40), 50 + RM.MANA_REGEN_BASE, "base-only inside 5s rule"
	)


func test_mana_spirit_regen_after_five_second_rule() -> void:
	# now=120 (>= 100 ticks since the tick-0 spend) and on the interval → full Spirit regen.
	var now := 120
	var expected := 50 + STC.mana_regen_per_interval(40)
	assert_eq(RM.regen_mana(50, 100, 0, now, 40), expected, "Spirit regen resumes after 5s")
	assert_gt(
		STC.mana_regen_per_interval(40),
		RM.MANA_REGEN_BASE,
		"Spirit regen exceeds base (rule matters)"
	)


func test_mana_regen_clamps_to_max() -> void:
	assert_eq(RM.regen_mana(99, 100, 0, 120, 40), 100, "mana never exceeds max")


# ---- Affordability + spend ----


func test_can_afford() -> void:
	assert_true(RM.can_afford(30, 25))
	assert_true(RM.can_afford(25, 25), "exact cost is affordable")
	assert_false(RM.can_afford(20, 25))


func test_spend_deducts_and_floors() -> void:
	assert_eq(RM.spend(30, 25), 5)
	assert_eq(RM.spend(10, 25), 0, "spend floors at 0")


# ---- Per-class initial resource ----


func test_initial_warrior_is_empty_rage() -> void:
	var r := RM.initial_for_class("warrior", 10)
	assert_eq(r["kind"], RM.RAGE)
	assert_eq(r["current"], 0, "warriors start with no rage — build it in combat")
	assert_eq(r["max"], RM.RAGE_MAX)


func test_initial_caster_is_full_mana() -> void:
	var r := RM.initial_for_class("mage", 30)
	assert_eq(r["kind"], RM.MANA)
	assert_eq(r["max"], STC.max_mana(30), "mana max from Intellect")
	assert_eq(r["current"], r["max"], "casters start at full mana")


func test_initial_unknown_class_is_none() -> void:
	var r := RM.initial_for_class("rogue", 30)
	assert_eq(r["kind"], RM.NONE, "no class resource until that class is added")
