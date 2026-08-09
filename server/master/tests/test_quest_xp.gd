extends "res://addons/gut/test.gd"
# T-621: over-level quest-XP decay math (quest_xp.gd) — pure. The authored quest XP pays FULL while
# the character is at-or-below questLevel+5, then steps 80/60/40/20/10% as they out-level it, never
# hitting zero (grey quests still pay 10%). questLevel == the quest's min_level; charLevel is truth.

const QXP = preload("res://scripts/quest_xp.gd")


func test_full_xp_at_or_below_cap() -> void:
	# Under-level, at level, and up to questLevel+5 all pay 100%.
	assert_eq(QXP.decay_pct(1, 10), 100, "far under-level = full")
	assert_eq(QXP.decay_pct(10, 10), 100, "at level = full")
	assert_eq(QXP.decay_pct(15, 10), 100, "questLevel+5 is still full (the cap boundary)")


func test_decay_steps_past_the_cap() -> void:
	assert_eq(QXP.decay_pct(16, 10), 80, "+6 over quest = 80%")
	assert_eq(QXP.decay_pct(17, 10), 60, "+7 = 60%")
	assert_eq(QXP.decay_pct(18, 10), 40, "+8 = 40%")
	assert_eq(QXP.decay_pct(19, 10), 20, "+9 = 20%")
	assert_eq(QXP.decay_pct(20, 10), 10, "+10 = 10% (grey floor)")


func test_grey_floor_never_zero() -> void:
	assert_eq(QXP.decay_pct(60, 1), 10, "wildly out-levelled still pays the 10% grey floor")
	assert_eq(QXP.decay_pct(99, 10), 10, "the tail clamps at 10%, never below")


func test_decayed_xp_scales_and_floors() -> void:
	assert_eq(QXP.decayed_xp(250, 10, 10), 250, "at level = full authored value")
	assert_eq(QXP.decayed_xp(250, 16, 10), 200, "+6 -> 80% of 250")
	assert_eq(QXP.decayed_xp(250, 20, 10), 25, "+10 -> 10% of 250")
	assert_eq(QXP.decayed_xp(255, 18, 10), 102, "+8 -> 40% of 255 = 102 (integer floor)")


func test_no_xp_quest_stays_zero() -> void:
	assert_eq(QXP.decayed_xp(0, 40, 1), 0, "a breadcrumb with no XP grants nothing")
	assert_eq(QXP.decayed_xp(-5, 40, 1), 0, "negative floored to zero")
