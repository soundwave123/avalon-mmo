extends "res://addons/gut/test.gd"
# T-361: ChatFormatter — channel colouring, self-describing tags, and BBCode injection safety.


func test_say_has_no_channel_tag() -> void:
	var got := ChatFormatter.format("say", "Alice", "hello")
	assert_eq(str(got["msg"]), "Alice: hello", "local say carries no channel prefix")
	assert_eq(got["color"], ChatFormatter.COLOR_SAY)


func test_party_and_world_are_tagged_and_coloured() -> void:
	var party := ChatFormatter.format("party", "Bob", "pull now")
	assert_true(str(party["msg"]).begins_with("[Party] "), "party lines are self-describing")
	assert_eq(party["color"], ChatFormatter.COLOR_PARTY)
	var world := ChatFormatter.format("world", "Cara", "wtb sword")
	assert_true(str(world["msg"]).begins_with("[World] "))
	assert_eq(world["color"], ChatFormatter.COLOR_WORLD)


func test_bbcode_is_neutralised() -> void:
	# A player cannot smuggle markup into the RichTextLabel via their name or text.
	var got := ChatFormatter.format("say", "Evil", "[color=red]hax[/color]")
	assert_false(str(got["msg"]).contains("[color=red]"), "opening brackets are escaped")


func test_system_notice_is_muted_red() -> void:
	var got := ChatFormatter.format_system("(rate_limited)")
	assert_eq(got["color"], ChatFormatter.COLOR_SYSTEM)


func test_emote_line_is_distinct_colour_and_escaped() -> void:
	# The server sends the whole resolved line; the formatter colours it orchid and neutralises markup.
	var got := ChatFormatter.format_emote("[b]Evil[/b] waves.")
	assert_eq(got["color"], ChatFormatter.COLOR_EMOTE, "emotes read in a distinct colour")
	assert_false(str(got["msg"]).contains("[b]"), "opening brackets are escaped")
	assert_true(str(got["msg"]).contains("waves."), "the action text is preserved")


# T-599: a duel-result line ("You won the duel against X!...") is relayed on channel "system" and
# rendered via format_system. A raw "[" in an interpolated name can spell a REAL bbcode tag (e.g.
# "[img]") that a bbcode-enabled RichTextLabel treats as consuming EVERYTHING after it to the end of
# the string — including the closing color tag — which is exactly the observed truncation ("You won
# the duel against pl" losing the rest of the name and the whole tail of the sentence). A string
# assertion alone can't catch this (the escaped string always "looks right"); the regression has to
# survive contact with an actual RichTextLabel.
func test_duel_result_line_survives_bracket_hostile_name_at_render() -> void:
	var hostile_name := "pl[img]ay7b"
	var line := "You won the duel against %s! (rating +12, +5 honor)" % hostile_name
	var got := ChatFormatter.format_system(line)
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	add_child_autofree(rtl)
	rtl.text = "[color=#%s]%s[/color]" % [(got["color"] as Color).to_html(false), str(got["msg"])]
	var parsed := rtl.get_parsed_text()
	assert_string_contains(
		parsed, "ay7b", "the tail of a bracket-hostile name must not be swallowed"
	)
	assert_string_contains(parsed, "honor", "the rest of the sentence must not be swallowed either")
