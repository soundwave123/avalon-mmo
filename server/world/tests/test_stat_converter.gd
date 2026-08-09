extends "res://addons/gut/test.gd"

# T-061: stat -> combat conversion. Pure module; assert formulas + monotonicity across stat values
# (the DoD's "measurably more as the stat rises"). No network, no engine loop, no OS time.

const STC = preload("res://scripts/combat/stat_converter.gd")

# ---- max_hp (Stamina stat) ----


func test_max_hp_base_at_zero_stamina() -> void:
	assert_eq(STC.max_hp(0), STC.HP_BASE, "0 stamina -> flat HP base")


func test_max_hp_l1_matches_legacy_spawn_hp() -> void:
	# L1 base stamina (10) must reproduce the old hardcoded spawn HP (100) for continuity.
	assert_eq(STC.max_hp(10), 100, "stamina 10 -> 50 + 10*5 = 100")


func test_max_hp_scales_with_stamina() -> void:
	assert_true(STC.max_hp(30) > STC.max_hp(10), "more stamina -> more HP")
	assert_eq(STC.max_hp(30), STC.HP_BASE + 30 * STC.HP_PER_STAMINA)


func test_max_hp_negative_stamina_clamped() -> void:
	assert_eq(STC.max_hp(-5), STC.HP_BASE, "negative stamina treated as 0")


# ---- max_mana (Intellect) — preserves M1 max_mana = int ----


func test_max_mana_equals_int() -> void:
	assert_eq(STC.max_mana(30), 350, "50 + int(30)*10 = 350")
	assert_eq(STC.max_mana(0), 50, "base mana at 0 int")


func test_max_mana_scales_with_int() -> void:
	assert_true(STC.max_mana(60) > STC.max_mana(30), "more int -> more mana")


# ---- swing_pool (Dex) — the UO swing-economy pool, NOT the stamina stat ----


func test_swing_pool_l1_preserves_m1_baseline() -> void:
	assert_eq(STC.swing_pool(10), 100, "L1 dex(10) -> 100 swing pool (matches old hardcoded pool)")
	assert_gt(STC.swing_pool(40), STC.swing_pool(10), "more dex -> larger swing pool")


# ---- mana regen (Spirit) — formula home for T-062 ----


func test_mana_regen_base_at_zero_spirit() -> void:
	assert_eq(STC.mana_regen_per_interval(0), STC.MANA_REGEN_BASE, "0 spirit -> base regen only")


func test_mana_regen_rises_with_spirit() -> void:
	assert_true(
		STC.mana_regen_per_interval(100) > STC.mana_regen_per_interval(0),
		"more spirit -> more mana regen"
	)


# ---- heal_power (Int primary, Spirit secondary) — formula home for T-063 ----


func test_heal_power_zero_at_zero_stats() -> void:
	assert_eq(STC.heal_power(0, 0), 0.0)


func test_heal_power_scales_with_int_and_spirit() -> void:
	assert_true(STC.heal_power(40, 0) > STC.heal_power(20, 0), "int raises heal power")
	assert_true(STC.heal_power(20, 40) > STC.heal_power(20, 0), "spirit raises heal power")
	assert_gt(STC.heal_power(40, 0), STC.heal_power(0, 40), "int weighted above spirit for healing")


func test_heal_power_negative_clamped() -> void:
	assert_eq(STC.heal_power(-10, -10), 0.0, "negative stats treated as 0")


# ---- T-295: derived_summary — the character-sheet view uses the SAME pool formulas ----


func test_derived_summary_matches_pool_formulas() -> void:
	var stats := {"str": 12, "int": 30, "dex": 40, "spirit": 20, "stamina": 25}
	var d := STC.derived_summary(stats)
	assert_eq(d["max_hp"], STC.max_hp(25), "sheet HP == pool HP (no drift)")
	assert_eq(d["max_mana"], STC.max_mana(30), "sheet mana == pool mana")
	assert_eq(d["endurance"], STC.swing_pool(40), "sheet endurance == swing pool")
	assert_eq(d["mana_regen"], STC.mana_regen_per_interval(20), "sheet regen == spirit regen")
	assert_eq(
		d["spell_power"],
		int(round(STC.heal_power(30, 20))),
		"spell power == heal_power (Int/Spirit)"
	)


func test_derived_summary_missing_stats_read_zero() -> void:
	var d := STC.derived_summary({})
	assert_eq(d["max_hp"], STC.max_hp(0), "empty vector -> base pools, no crash")
	assert_eq(d["max_mana"], STC.max_mana(0))


func test_derived_hp_rises_with_stamina() -> void:
	var lo := STC.derived_summary({"stamina": 10})
	var hi := STC.derived_summary({"stamina": 40})
	assert_gt(int(hi["max_hp"]), int(lo["max_hp"]), "more STA -> more HP on the sheet")


# ---- T-295: player_stats_msg — one payload shape for spawn + level-up ----


func test_player_stats_msg_carries_primaries_and_derived() -> void:
	var combat := {
		"level": 5,
		"xp_into_level": 40,
		"xp_for_next_level": 200,
		"stats": {"str": 22, "int": 10, "dex": 14, "spirit": 10, "stamina": 22},
	}
	var msg := STC.player_stats_msg(combat)
	assert_eq(msg["type"], "player_stats")
	assert_eq(int(msg["level"]), 5)
	assert_eq(int(msg["xp_into_level"]), 40)
	assert_eq(int(msg["primaries"]["str"]), 22, "primaries carried through")
	assert_eq(int(msg["primaries"]["stamina"]), 22)
	assert_eq(
		int(msg["derived"]["max_hp"]), STC.max_hp(22), "derived HP built from the STA primary"
	)


func test_player_stats_msg_defaults_when_stats_empty() -> void:
	var msg := STC.player_stats_msg({"level": 1})
	assert_eq(int(msg["level"]), 1)
	assert_eq(int(msg["primaries"]["str"]), 0, "no stats -> zeroed primaries, no crash")
	assert_true(msg.has("derived"))


# T-712: the master's talent_points (talent_logic points_available truth) rides the same push, so
# the level-up banner can name the earned point without the client mirroring the rule.
func test_player_stats_msg_carries_talent_points() -> void:
	assert_eq(int(STC.player_stats_msg({"level": 2, "talent_points": 1})["talent_points"]), 1)
	assert_eq(
		int(STC.player_stats_msg({"level": 1})["talent_points"]),
		0,
		"a payload without the field degrades to 0, never a crash"
	)
