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


# ---- T-755: combatant names are player text on a bbcode surface ----------------
#
# These lines are rendered into TWO different bbcode_enabled labels (combat_log_panel, and
# chat_panel for the combat channel), so the escape lives at the formatter's entry point rather
# than in either consumer — a third consumer cannot forget it.
func _parsed(msg: String) -> String:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	add_child_autofree(rtl)
	rtl.text = msg
	return rtl.get_parsed_text()


func test_hostile_combatant_names_are_escaped_in_every_outcome_branch() -> void:
	# format_ability has five separate return paths and the original bug was that ALL of them
	# interpolated names raw — so all five are pinned, not just the common hit line.
	var hostile := "[color=red]mal"
	for outcome in ["hit", "crit", "miss", "dodge", "parry"]:
		var line: Dictionary = F.format_ability(1, hostile, 2, "victim", 7, outcome, -1, 99)
		assert_false(
			str(line["msg"]).contains("[color=red]"),
			"'%s' branch must not emit a live tag" % outcome
		)
		assert_string_contains(
			_parsed(str(line["msg"])), hostile, "'%s' branch renders the name literally" % outcome
		)
		assert_string_contains(
			_parsed(str(line["msg"])),
			"victim",
			"'%s' branch: the rest of the line survives" % outcome
		)


func test_falling_heal_and_loot_lines_escape_their_player_text() -> void:
	# The fall-damage branch names only the TARGET (no caster), so it is a distinct path.
	var fall: Dictionary = F.format_ability(
		0, "", 2, "[b]faller", 7, "hit", -1, 99, false, "falling"
	)
	assert_string_contains(_parsed(str(fall["msg"])), "[b]faller", "fall line escapes the target")
	var heal := F.format_heal("[i]healer", "[u]patient", 40, -1)
	assert_string_contains(_parsed(str(heal["msg"])), "[i]healer", "heal escapes the caster")
	assert_string_contains(_parsed(str(heal["msg"])), "[u]patient", "heal escapes the target")
	var loot := F.format_loot("[url=evil]a Sword[/url]")
	assert_false(str(loot["msg"]).contains("[url=evil]"), "an item name cannot open a live tag")
	assert_string_contains(
		_parsed(str(loot["msg"])), "[url=evil]a Sword[/url]", "loot renders flat"
	)


func test_escaping_leaves_an_ordinary_combat_line_byte_identical() -> void:
	# The escape must be invisible in normal play — every name the server can send today is
	# bracket-free, so these lines must read exactly as they did before T-755.
	var line := F.format_ability(1, "aldric", 2, "grey_wolf", 12, "hit", -1, 1)
	assert_eq(str(line["msg"]), "aldric hits grey_wolf for 12 damage.")
	assert_eq(str(F.format_heal("aldric", "bob", 40, -1)["msg"]), "aldric heals bob for 40.")
