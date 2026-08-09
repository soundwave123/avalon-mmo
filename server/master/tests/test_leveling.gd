extends "res://addons/gut/test.gd"
# T-035: Pure XP curve + per-class stat table.

const LV = preload("res://scripts/leveling.gd")


func test_total_xp_for_level() -> void:
	assert_eq(LV.total_xp_for_level(1), 0)
	assert_eq(LV.total_xp_for_level(2), 100)
	assert_eq(LV.total_xp_for_level(3), 300)
	assert_eq(LV.total_xp_for_level(4), 600)


func test_level_for_total_xp() -> void:
	assert_eq(LV.level_for_total_xp(0), 1)
	assert_eq(LV.level_for_total_xp(99), 1)
	assert_eq(LV.level_for_total_xp(100), 2)
	assert_eq(LV.level_for_total_xp(299), 2)
	assert_eq(LV.level_for_total_xp(300), 3)


func test_level_caps_at_max() -> void:
	assert_eq(LV.level_for_total_xp(99999999), LV.MAX_LEVEL)


func test_apply_xp_levels_up() -> void:
	var r = LV.apply_xp(1, 0, 100)
	assert_eq(r["level"], 2)
	assert_eq(r["xp"], 100)
	assert_true(r["leveled_up"])
	assert_eq(r["levels_gained"], 1)


func test_apply_xp_no_levelup() -> void:
	var r = LV.apply_xp(2, 100, 50)
	assert_eq(r["level"], 2)
	assert_false(r["leveled_up"])


func test_apply_xp_multi_level() -> void:
	var r = LV.apply_xp(1, 0, 600)
	assert_eq(r["level"], 4)
	assert_true(r["levels_gained"] >= 2)


func test_apply_xp_caps_at_max_level() -> void:
	var r = LV.apply_xp(1, 0, 99999999)
	assert_eq(r["level"], LV.MAX_LEVEL)


func test_apply_xp_negative_floored() -> void:
	var r = LV.apply_xp(2, 100, -500)
	assert_eq(r["xp"], 0)
	assert_eq(r["level"], 1)


func test_stats_for_level_base_and_growth() -> void:
	var s1 = LV.stats_for_level("warrior", 1)
	var s2 = LV.stats_for_level("warrior", 2)
	assert_eq(s1["str"], 10)
	assert_true(s2["str"] > s1["str"])


func test_stats_mage_grows_int() -> void:
	var s1 = LV.stats_for_level("mage", 1)
	var s2 = LV.stats_for_level("mage", 2)
	assert_true(s2["int"] > s1["int"])


func test_stats_unknown_class_falls_back_to_warrior() -> void:
	assert_eq(LV.stats_for_level("unknown_xyz", 5), LV.stats_for_level("warrior", 5))


# T-061: spirit + stamina added to the per-class stat table.


func test_stats_for_level_includes_spirit_and_stamina() -> void:
	var s = LV.stats_for_level("warrior", 1)
	assert_true(s.has("spirit"), "stat table exposes spirit")
	assert_true(s.has("stamina"), "stat table exposes stamina")
	assert_eq(s["stamina"], 10, "L1 base stamina = 10 (-> 100 HP via stat_converter)")


func test_stats_warrior_grows_stamina() -> void:
	assert_gt(
		LV.stats_for_level("warrior", 10)["stamina"],
		LV.stats_for_level("warrior", 1)["stamina"],
		"warrior gains stamina (HP) per level"
	)


func test_stats_priest_grows_spirit() -> void:
	assert_gt(
		LV.stats_for_level("priest", 10)["spirit"],
		LV.stats_for_level("priest", 1)["spirit"],
		"priest gains spirit (regen/healing) per level"
	)


func test_stats_warrior_tankier_than_mage() -> void:
	assert_gt(
		LV.stats_for_level("warrior", 15)["stamina"],
		LV.stats_for_level("mage", 15)["stamina"],
		"class identity: warrior has more stamina (HP) than mage at cap"
	)


# ---- T-295: per-class level-up growth (data-driven; primaries STR/STA/DEX/INT) ----


# Leveling a warrior several times raises STR + STA per the table; INT stays flat.
func test_warrior_levelup_growth_str_sta_not_int() -> void:
	var l1 := LV.stats_for_level("warrior", 1)
	var l6 := LV.stats_for_level("warrior", 6)  # 5 level-ups
	assert_eq(l6["str"], l1["str"] + 5 * 3, "warrior +3 STR/level over 5 level-ups")
	assert_eq(l6["stamina"], l1["stamina"] + 5 * 3, "warrior +3 STA/level")
	assert_eq(l6["int"], l1["int"], "warrior INT does not grow")


# Leveling a mage raises INT (not STR); confirms class-keyed growth from the data file.
func test_mage_levelup_grows_int_not_str() -> void:
	var l1 := LV.stats_for_level("mage", 1)
	var l6 := LV.stats_for_level("mage", 6)
	assert_eq(l6["int"], l1["int"] + 5 * 3, "mage +3 INT/level")
	assert_eq(l6["str"], l1["str"], "mage STR does not grow")


# The authored data file (data/class_growth.json) is what actually drives the table — not a stale
# in-code copy. Load it directly and assert it agrees with stats_for_level for a spread of classes.
func test_growth_data_file_drives_the_table() -> void:
	var path := "res://data/class_growth.json"
	assert_true(FileAccess.file_exists(path), "authored growth JSON is present")
	var parsed: Variant = JSON.parse_string(FileAccess.open(path, FileAccess.READ).get_as_text())
	assert_true(parsed is Dictionary, "growth JSON parses")
	var base: Dictionary = parsed["base"]
	var per_level: Dictionary = parsed["per_level"]
	for cls: String in ["warrior", "mage", "priest"]:
		var lvl := 8
		var expected: Dictionary = {}
		for stat: String in base:
			expected[stat] = int(base[stat]) + int(per_level[cls].get(stat, 0)) * (lvl - 1)
		assert_eq(
			LV.stats_for_level(cls, lvl), expected, "%s L%d matches the data file" % [cls, lvl]
		)


# ---- T-060: XP-bar progress view ----


func test_progress_mid_level_and_max() -> void:
	var mid: Dictionary = LV.progress(2, 150)  # L2 floor 100, span 200
	assert_eq(int(mid["xp_into_level"]), 50)
	assert_eq(int(mid["xp_for_next_level"]), 200)
	var maxed: Dictionary = LV.progress(LV.MAX_LEVEL, LV.total_xp_for_level(LV.MAX_LEVEL) + 42)
	assert_eq(int(maxed["xp_for_next_level"]), 0, "max level has no next span")


# ---- T-368: cap parameterized to the owner-blessed era bands; Era-2 live cap = 40. ----


func test_cap_is_forty() -> void:
	assert_eq(LV.MAX_LEVEL, 40, "Era-2 (Ashmoor) live cap: players reach L40")


# The cap is a PARAMETER of the active era band, not a free-floating literal. Guard the two so a
# future era flip (ACTIVE_ERA) cannot silently disagree with the shipped MAX_LEVEL.
func test_cap_matches_active_era_band() -> void:
	assert_eq(
		LV.MAX_LEVEL, int(LV.ERA_LEVEL_CAPS[LV.ACTIVE_ERA]), "MAX_LEVEL == active era band cap"
	)
	assert_eq(LV.cap_for_era(1), 20, "Era-1 caps at 20")
	assert_eq(LV.cap_for_era(2), 40, "Era-2 caps at 40")
	assert_eq(LV.cap_for_era(3), 60, "Era-3 caps at 60")
	assert_eq(LV.cap_for_era(99), LV.MAX_LEVEL, "unknown era falls back to the active cap")


# T-368 REGRESSION: raising the clamp 20 -> 40 must not perturb a single Era-1 XP threshold. These
# are the pinned pre-change values of 50*(L-1)*L for L1..20 — byte-identical before and after.
func test_era1_curve_byte_identical() -> void:
	var era1 := [
		0,
		100,
		300,
		600,
		1000,
		1500,
		2100,
		2800,
		3600,
		4500,
		5500,
		6600,
		7800,
		9100,
		10500,
		12000,
		13600,
		15300,
		17100,
		19000,
	]
	for i in range(era1.size()):
		assert_eq(LV.total_xp_for_level(i + 1), era1[i], "L%d total XP unchanged" % (i + 1))


func test_curve_extends_through_l21_to_l40() -> void:
	# 50*(L-1)*L, integer-exact, across the new Era-2 band.
	assert_eq(LV.total_xp_for_level(20), 19000)
	assert_eq(LV.total_xp_for_level(21), 21000)
	assert_eq(LV.total_xp_for_level(30), 43500)
	assert_eq(LV.total_xp_for_level(40), 78000)
	# The cap holds: L41 clamps to the L40 floor.
	assert_eq(LV.total_xp_for_level(41), LV.total_xp_for_level(40))


func test_level_reaches_forty_and_caps_there() -> void:
	assert_eq(LV.level_for_total_xp(LV.total_xp_for_level(20)), 20)
	assert_eq(LV.level_for_total_xp(LV.total_xp_for_level(40)), 40)
	assert_eq(LV.level_for_total_xp(LV.total_xp_for_level(40) - 1), 39)
	assert_eq(LV.level_for_total_xp(99999999), 40, "hard cap at L40, not L20")


func test_stat_growth_extends_to_l40() -> void:
	# Linear growth: a warrior at L40 has 39 level-ups of +3 STR over the L1 base.
	var l1 := LV.stats_for_level("warrior", 1)
	var l40 := LV.stats_for_level("warrior", 40)
	assert_eq(l40["str"], l1["str"] + 39 * 3, "warrior +3 STR/level all the way to L40")
	assert_eq(l40["stamina"], l1["stamina"] + 39 * 3, "warrior +3 STA/level to L40")
	# L41 clamps to the L40 vector (no growth past the cap).
	assert_eq(LV.stats_for_level("warrior", 41), l40, "stats clamp at the cap")
