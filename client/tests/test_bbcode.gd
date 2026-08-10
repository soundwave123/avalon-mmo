extends "res://addons/gut/test.gd"
# T-755: BBCode — the shared neutraliser for player-controlled text bound for a bbcode_enabled
# RichTextLabel. These tests pin the two DIFFERENT contracts (display vs meta payload), because the
# whole bug class comes from using one where the other was needed.


func _parsed(bbcode: String) -> String:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	add_child_autofree(rtl)
	rtl.text = bbcode
	return rtl.get_parsed_text()


func test_escape_neutralises_every_tag_opener() -> void:
	assert_eq(BBCode.escape("[b]"), "[lb]b]")
	assert_eq(BBCode.escape("[url=kick|bob]x[/url]"), "[lb]url=kick|bob]x[lb]/url]")
	assert_eq(BBCode.escape("a[b[c"), "a[lb]b[lb]c", "every occurrence, not just the first")


func test_escape_leaves_innocent_text_untouched() -> void:
	# The escape must not tax normal play: a name, a sentence, punctuation and a lone closing
	# bracket are all inert already and must round-trip byte-identically.
	for s in ["aldric", "Weekends only, EU evenings!", "50% off", "closing ] alone", ""]:
		assert_eq(BBCode.escape(s), s, "'%s' needs no escaping" % s)


func test_escaped_payload_renders_as_literal_text() -> void:
	# The claim the fix actually rests on: after escape(), a bbcode_enabled label DISPLAYS the
	# attacker's markup instead of ACTING on it. If the tag were still live, "[url=" would be
	# consumed by the parser and absent from the parsed text.
	var hostile := "[url=evil]click[/url] and [color=red]red"
	var parsed := _parsed(BBCode.escape(hostile))
	assert_eq(parsed, hostile, "what the player typed is what the player sees, inert")


func test_unescaped_payload_really_would_be_live_markup() -> void:
	# The negative control. Without this, the test above could pass against a label that simply
	# never parsed anything — this proves the parser IS live and the escape is what tames it.
	var parsed := _parsed("[url=evil]click[/url] tail")
	assert_false(parsed.contains("[url=evil]"), "unescaped, the tag is consumed as real markup")
	assert_string_contains(parsed, "click", "...leaving only its clickable label behind")


func test_escape_meta_strips_tag_and_argument_separators() -> void:
	# Inside [url=...] the "[lb]" entity would be stored literally into the meta rather than
	# rendered, so a payload is STRIPPED instead: "]" would close the tag early and "|" would shift
	# the argument positions the panels' str(meta).split("|") reads.
	assert_eq(BBCode.escape_meta("bo]b"), "bob")
	assert_eq(BBCode.escape_meta("bob|kick|alice"), "bobkickalice")
	assert_eq(BBCode.escape_meta("[b]bob"), "bbob")


func test_escape_meta_is_the_identity_for_a_legal_character_name() -> void:
	# character_name.gd restricts stored names to ^[a-z0-9_-]{3,20}$, so for every name the server
	# can actually hand us today this function changes nothing. It is the guard for the day that
	# rule loosens — and this test is what will notice if the two rules ever drift apart.
	for name in ["aldric", "bob_the-third", "x9-_a"]:
		assert_eq(BBCode.escape_meta(name), name, "'%s' is a legal name, passed through" % name)
