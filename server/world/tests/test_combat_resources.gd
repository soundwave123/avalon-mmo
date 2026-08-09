extends "res://addons/gut/test.gd"

# T-016: Resources — HP / mana / stamina, server-authoritative
# Pure-function tests; no network, no engine, no OS time.

const CombatResources = preload("res://scripts/combat/combat_resources.gd")
const ServerConfig = preload("res://scripts/server_config.gd")


# Helper: create a fresh CombatResources from an attribute vector (T-061: HP from stamina,
# mana from int, swing pool from dex). str/spirit don't affect pools, so they're omitted here.
func _make_resources(
	int_val: int = 30, dex_val: int = 40, stamina_val: int = 50
) -> CombatResources:
	var stats := CharacterStats.new()
	stats.int_val = int_val
	stats.dex_val = dex_val
	stats.stamina_val = stamina_val
	var res := CombatResources.new()
	res.derive_from_stats(stats)
	return res


# ---- derive_from_stats (T-061: HP from Stamina, mana from Int, swing pool from Dex) ----


func test_derive_from_stats_hp_from_stamina() -> void:
	var res := _make_resources(30, 40, 50)
	assert_eq(res.max_hp, 300, "HP_BASE(50) + stamina(50)*5 = 300")


func test_derive_from_stats_hp_scales_with_stamina() -> void:
	# The L67 fix: HP is no longer flat — more stamina (which grows with level) = more HP.
	assert_true(
		_make_resources(30, 40, 100).max_hp > _make_resources(30, 40, 20).max_hp,
		"more stamina -> more max HP"
	)


func test_derive_from_stats_produces_correct_max_mana() -> void:
	assert_eq(_make_resources(30, 40, 50).max_mana, 350, "50 + INT(30)*10 = 350")


func test_derive_from_stats_produces_correct_max_stamina_pool() -> void:
	assert_eq(_make_resources(30, 40, 50).max_stamina, 130, "swing pool = 90 + DEX(40)")


func test_derive_from_stats_sets_current_to_max() -> void:
	var res := _make_resources(30, 40, 50)
	assert_eq(res.hp, res.max_hp, "hp starts at max")
	assert_eq(res.mana, res.max_mana, "mana starts at max")
	assert_eq(res.stamina, res.max_stamina, "stamina starts at max")


func test_derive_from_stats_different_stats() -> void:
	var res := _make_resources(60, 80, 100)
	assert_eq(res.max_hp, 550, "50 + stamina(100)*5 = 550")
	assert_eq(res.max_mana, 650, "50 + INT(60)*10 = 650")
	assert_eq(res.max_stamina, 170, "swing pool = 90 + DEX(80)")


# ---- apply_damage ----


func test_apply_damage_reduces_hp() -> void:
	var res := _make_resources()
	var result := res.apply_damage(10)
	assert_eq(result.hp, res.max_hp - 10, "hp reduced by exactly 10")
	assert_eq(result.mana, res.max_mana, "mana unchanged")
	assert_eq(result.stamina, res.max_stamina, "stamina unchanged")


func test_apply_damage_clamps_to_zero_not_negative() -> void:
	var res := _make_resources()
	var result := res.apply_damage(res.max_hp + 1)
	assert_eq(result.hp, 0, "hp clamped to 0, not negative")


func test_apply_damage_zero_hp_does_not_go_negative() -> void:
	var res := _make_resources()
	var result := res.apply_damage(res.max_hp)
	assert_eq(result.hp, 0, "hp exactly 0 after max_hp damage")


func test_apply_damage_returns_new_instance() -> void:
	var res := _make_resources()
	var original_hp := res.hp
	var result := res.apply_damage(10)
	assert_eq(res.hp, original_hp, "original resource unchanged (pure function)")
	assert_eq(result.hp, original_hp - 10, "new resource has reduced hp")


# ---- apply_heal ----


func test_apply_heal_increases_hp() -> void:
	var res := _make_resources()
	res = res.apply_damage(20)  # take damage first
	var result := res.apply_heal(15)
	assert_eq(result.hp, res.max_hp - 5, "hp increased by 15")


func test_apply_heal_clamps_to_max_not_above() -> void:
	var res := _make_resources()
	# At full HP, healing more should clamp
	var result := res.apply_heal(res.max_hp + 100)
	assert_eq(result.hp, res.max_hp, "hp clamped to max, not above")


func test_apply_heal_from_zero_clamped() -> void:
	var res := _make_resources()
	var damaged := res.apply_damage(res.max_hp)  # hp = 0
	var result := damaged.apply_heal(res.max_hp + 10)
	assert_eq(result.hp, res.max_hp, "heal from 0 clamped to max")


func test_apply_heal_returns_new_instance() -> void:
	var res := _make_resources()
	res = res.apply_damage(20)
	var original_hp := res.hp
	var result := res.apply_heal(15)
	assert_eq(res.hp, original_hp, "original unchanged")
	assert_eq(result.hp, original_hp + 15, "new hp increased")


# ---- apply_mana_cost ----


func test_apply_mana_cost_deducts_mana() -> void:
	var res := _make_resources()
	var result := res.apply_mana_cost(10)
	assert_eq(result.mana, res.max_mana - 10, "mana reduced by cost")
	assert_eq(result.hp, res.max_hp, "hp unchanged")


func test_apply_mana_cost_clamps_to_zero() -> void:
	var res := _make_resources()
	var result := res.apply_mana_cost(res.max_mana + 1)
	assert_eq(result.mana, 0, "mana clamped to 0")


func test_apply_mana_cost_insufficient_returns_clamped() -> void:
	var res := _make_resources()
	res.mana = 5  # low mana
	var result := res.apply_mana_cost(20)
	assert_eq(
		result.mana, 0, "mana clamped to 0 (validation layer catches insufficient before commit)"
	)
	assert_eq(result.hp, res.max_hp, "hp unchanged")


func test_apply_mana_cost_returns_new_instance() -> void:
	var res := _make_resources()
	var original_mana := res.mana
	var result := res.apply_mana_cost(10)
	assert_eq(res.mana, original_mana, "original unchanged")
	assert_eq(result.mana, original_mana - 10, "new mana reduced")


# ---- apply_stamina_drain ----


func test_apply_stamina_drain_reduces_stamina() -> void:
	var res := _make_resources()
	var result := res.apply_stamina_drain(10)
	assert_eq(result.stamina, res.max_stamina - 10, "stamina reduced by drain")
	assert_eq(result.hp, res.max_hp, "hp unchanged")
	assert_eq(result.mana, res.max_mana, "mana unchanged")


func test_apply_stamina_drain_clamps_to_zero() -> void:
	var res := _make_resources()
	var result := res.apply_stamina_drain(res.max_stamina + 1)
	assert_eq(result.stamina, 0, "stamina clamped to 0")


func test_apply_stamina_drain_returns_new_instance() -> void:
	var res := _make_resources()
	var original_stamina := res.stamina
	var result := res.apply_stamina_drain(10)
	assert_eq(res.stamina, original_stamina, "original unchanged")
	assert_eq(result.stamina, original_stamina - 10, "new stamina reduced")


# ---- regen_vitals_tick ----


func test_regen_vitals_tick_no_regen_before_interval() -> void:
	var res := _make_resources()
	var damaged := res.apply_damage(10)
	# tick 1 — interval not hit (HP_REGEN_INTERVAL = 20, i.e., every 20 ticks)
	var result := damaged.regen_vitals_tick(1)
	assert_eq(result.hp, damaged.hp, "no regen before interval hit")


func test_regen_vitals_tick_regen_at_interval() -> void:
	var res := _make_resources()
	var damaged := res.apply_damage(10)
	var interval := ServerConfig.get_hp_regen_interval()
	var result := damaged.regen_vitals_tick(interval)
	assert_eq(
		result.hp,
		damaged.hp + ServerConfig.get_hp_regen_per_interval(),
		"hp increased by regen rate at interval"
	)


func test_regen_vitals_tick_multiple_intervals() -> void:
	var res := _make_resources()
	var damaged := res.apply_damage(50)
	var interval := ServerConfig.get_hp_regen_interval()
	var rate := ServerConfig.get_hp_regen_per_interval()
	# Advance clock through 5 intervals
	var current := damaged
	for i in range(1, 6):
		current = current.regen_vitals_tick(i * interval)
	assert_eq(current.hp, damaged.hp + 5 * rate, "hp increased by 5 * rate after 5 intervals")
	# Verify cap
	assert_true(current.hp <= res.max_hp, "hp never exceeds max")


func test_regen_vitals_tick_clamps_to_max() -> void:
	var res := _make_resources()
	var interval := ServerConfig.get_hp_regen_interval()
	# Already at max — regen should not push above
	var result := res.regen_vitals_tick(interval)
	assert_eq(result.hp, res.max_hp, "regen does not exceed max")


func test_regen_vitals_tick_leaves_mana_alone() -> void:
	# T-071: mana belongs to the class-resource model (T-062 five-second rule) — the vitals
	# regen regenerating it too was a double-dip.
	var res := _make_resources()
	var drained := res.apply_mana_cost(10)
	var interval := ServerConfig.get_mana_regen_interval()
	var result := drained.regen_vitals_tick(interval)
	assert_eq(result.mana, drained.mana, "vitals regen must NOT touch mana")


func test_regen_vitals_tick_stamina_regen() -> void:
	var res := _make_resources()
	var drained := res.apply_stamina_drain(10)
	var interval := ServerConfig.get_stamina_regen_interval()
	var result := drained.regen_vitals_tick(interval)
	assert_eq(
		result.stamina,
		drained.stamina + ServerConfig.get_stamina_regen_per_interval(),
		"stamina regen at interval"
	)


func test_regen_vitals_tick_does_not_fire_when_dead() -> void:
	var res := _make_resources()
	var dead := res.apply_damage(res.max_hp)  # hp = 0
	var interval := ServerConfig.get_hp_regen_interval()
	var result := dead.regen_vitals_tick(interval)
	assert_eq(result.hp, 0, "no regen when hp is 0 (Dead)")


# ---- Fuzz: 1000 random pairs ----


func test_fuzz_hp_never_below_zero_or_above_max() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in range(1000):
		var stamina_val := rng.randi_range(10, 200)
		var res := _make_resources(30, 40, stamina_val)
		var result: CombatResources = res
		for _j in range(50):
			var dmg := rng.randi_range(0, res.max_hp + 50)
			result = result.apply_damage(dmg)
			if rng.randf() < 0.3:
				var heal := rng.randi_range(0, res.max_hp)
				result = result.apply_heal(heal)
			if rng.randf() < 0.2:
				result = result.regen_vitals_tick(rng.randi_range(1, 100))
		assert_true(result.hp >= 0, "hp never below 0 (iter %d, hp=%d)" % [i, result.hp])
		assert_true(
			result.hp <= res.max_hp,
			"hp never above max (iter %d, hp=%d, max=%d)" % [i, result.hp, res.max_hp]
		)


# ---- Negation guard: negative damage rejected ----


func test_apply_damage_negative_amount_rejected() -> void:
	var res := _make_resources()
	var original_hp := res.hp
	# Negative damage should be treated as 0 (no-op guard against upstream bugs)
	var result := res.apply_damage(-10)
	assert_eq(result.hp, original_hp, "negative damage treated as 0, hp unchanged")


func test_apply_heal_negative_amount_rejected() -> void:
	var res := _make_resources()
	var original_hp := res.hp
	var result := res.apply_heal(-10)
	assert_eq(result.hp, original_hp, "negative heal treated as 0")


# ---- T-062: class resource (kind-keyed) ----


func test_set_class_resource_warrior_is_empty_rage() -> void:
	var res := CombatResources.new()
	res.set_class_resource("warrior", 30)
	assert_eq(res.resource_kind, "rage")
	assert_eq(res.class_resource(), 0, "warriors start with no rage")
	assert_eq(res.class_resource_max(), 100)


func test_set_class_resource_mage_is_full_mana() -> void:
	var res := CombatResources.new()
	res.set_class_resource("mage", 30)
	assert_eq(res.resource_kind, "mana")
	assert_eq(res.class_resource(), res.class_resource_max(), "casters start at full mana")
	assert_eq(res.class_resource_max(), 350, "mana max = 50 + INT(30)*10")


func test_class_resource_none_for_unknown_class() -> void:
	var res := CombatResources.new()
	res.set_class_resource("rogue", 30)
	assert_eq(res.resource_kind, "none")
	assert_eq(res.class_resource(), 0)


func test_with_class_resource_clamps_and_is_pure() -> void:
	var res := CombatResources.new()
	res.set_class_resource("warrior", 10)  # rage 0..100
	var bumped := res.with_class_resource(150)
	assert_eq(bumped.class_resource(), 100, "clamped to max")
	assert_eq(res.class_resource(), 0, "original unchanged (pure)")


func test_spend_class_resource_records_spend_tick() -> void:
	var res := CombatResources.new()
	res.set_class_resource("mage", 30)  # mana 30
	var after := res.spend_class_resource(25, 500)
	assert_eq(after.class_resource(), 325, "mana spent (350 - 25)")
	assert_eq(after.last_spend_tick, 500, "spend tick recorded for the 5-second rule")


func test_mark_combat_records_tick() -> void:
	var res := CombatResources.new()
	res.set_class_resource("warrior", 10)
	assert_eq(res.mark_combat(742).last_combat_tick, 742, "combat tick recorded for rage decay")
