extends GutTest

# T-308: the combat-log formatter — strips the raw [tick=NNN] prefix by default and colours entries
# by their meaning relative to the local player.

const F = preload("res://scripts/ui/combat_log_formatter.gd")

const LOCAL := 55
const MOB := 900


func test_tick_prefix_stripped_by_default() -> void:
	var line := F.format_ability(LOCAL, "You", MOB, "Wolf", 13, "hit", 1150135, LOCAL)
	assert_false(line["msg"].contains("[tick="), "raw tick id is hidden in the normal feed")


func test_tick_prefix_kept_behind_debug_flag() -> void:
	var line := F.format_ability(LOCAL, "You", MOB, "Wolf", 13, "hit", 1150135, LOCAL, true)
	assert_true(line["msg"].contains("[tick=1150135]"), "debug flag re-enables the tick id")


func test_your_hit_is_gold() -> void:
	var line := F.format_ability(LOCAL, "You", MOB, "Wolf", 13, "hit", -1, LOCAL)
	assert_eq(line["category"], "your_hit")
	assert_eq(line["color"], F.COLOR_YOUR_HIT)


func test_damage_taken_is_red() -> void:
	var line := F.format_ability(MOB, "Wolf", LOCAL, "You", 13, "hit", -1, LOCAL)
	assert_eq(line["category"], "damage_taken")
	assert_eq(line["color"], F.COLOR_DAMAGE_TAKEN)


func test_crit_is_orange() -> void:
	var line := F.format_ability(MOB, "Wolf", LOCAL, "You", 26, "crit", -1, LOCAL)
	assert_eq(line["category"], "crit")
	assert_eq(line["color"], F.COLOR_CRIT)
	assert_true(line["msg"].contains("critically"))


func test_miss_is_grey() -> void:
	var line := F.format_ability(LOCAL, "You", MOB, "Wolf", 0, "dodge", -1, LOCAL)
	assert_eq(line["category"], "miss")
	assert_eq(line["color"], F.COLOR_MISS)


func test_heal_is_green() -> void:
	var line := F.format_heal("Priest", "You", 40, -1)
	assert_eq(line["category"], "heal")
	assert_eq(line["color"], F.COLOR_HEAL)


func test_loot_is_blue() -> void:
	var line := F.format_loot("a Rusty Sword")
	assert_eq(line["category"], "loot")
	assert_eq(line["color"], F.COLOR_LOOT)
	assert_true(line["msg"].contains("Rusty Sword"))
