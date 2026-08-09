extends "res://addons/gut/test.gd"
# T-621: quest difficulty colour bands (quest_difficulty.gd) — pure. Maps (questLevel - charLevel)
# the WoW colour the client paints on the log / tracker / offer card. The colours ARE the pacing UI.

const QD = preload("res://scripts/content/quest_difficulty.gd")


func test_red_band_well_above_level() -> void:
	assert_eq(QD.color(15, 10), "red", "+5 delta = red (very hard)")
	assert_eq(QD.color(20, 10), "red", "far above = red")


func test_orange_band() -> void:
	assert_eq(QD.color(13, 10), "orange", "+3 = orange")
	assert_eq(QD.color(14, 10), "orange", "+4 = orange")


func test_yellow_intended_band() -> void:
	assert_eq(QD.color(12, 10), "yellow", "+2 = yellow (top of the intended band)")
	assert_eq(QD.color(10, 10), "yellow", "at level = yellow")
	assert_eq(QD.color(8, 10), "yellow", "-2 = yellow (bottom of the intended band)")


func test_green_below_but_not_trivial() -> void:
	# charLevel 10: grey cutoff = 10 - 1 - 5 = 4. quest L5..L7 are green (easy, not yet trivial).
	assert_eq(QD.color(7, 10), "green", "-3 and above the grey cutoff = green")
	assert_eq(QD.color(5, 10), "green", "just above the grey cutoff = green")


func test_grey_trivial_band() -> void:
	# charLevel 10: cutoff 4 — quests at/below 4 are trivial grey.
	assert_eq(QD.color(4, 10), "grey", "at the grey cutoff = grey")
	assert_eq(QD.color(1, 10), "grey", "far below = grey")


func test_grey_cutoff_formula() -> void:
	assert_eq(QD.grey_level(10), 4)
	assert_eq(QD.grey_level(20), 13)
	assert_eq(QD.grey_level(5), 0, "below the 6-49 band clamps to 0 (nothing is trivial yet)")


func test_low_level_has_no_grey() -> void:
	# A fresh L3 character: green floor never collapses to grey (cutoff clamped to 0).
	assert_eq(QD.color(1, 3), "yellow", "±2 band still yellow")
	assert_ne(QD.color(1, 5), "grey", "no trivial quests below the band")
