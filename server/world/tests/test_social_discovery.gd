extends GutTest

# T-451: pure looking-for-guild and /who logic. All authoritative fields are injected from world
# truth maps; the only player-authored seeker field is the bounded note.

const Discovery = preload("res://scripts/social_discovery.gd")


func test_seeker_board_carries_server_truth_and_prunes_guilded_players() -> void:
	var store := Discovery.new_store()
	Discovery.flag(store, 7, 12, "dps", "Weeknight quests")
	var row: Dictionary = Discovery.board(store)[0]
	assert_eq(int(row["level"]), 12)
	assert_eq(str(row["role"]), "dps")
	assert_eq(str(row["note"]), "Weeknight quests")
	assert_eq(Discovery.prune_guilded(store, {7: 44}), [7])
	assert_eq(Discovery.board(store).size(), 0, "guild join clears the seeking signal")


func test_who_builds_rows_from_server_maps_and_filters() -> void:
	var positions := {
		1: {"username": "Alice", "x": 0.0, "z": 0.0, "instance_id": 0},
		2: {"username": "Bob", "x": -420.0, "z": 0.0, "instance_id": 0},
	}
	var rows := Discovery.who(
		positions,
		{1: 17, 2: 9},
		{1: "mage", 2: "warrior"},
		{1: 5},
		{1: "Knights"},
		{"role": "dps", "min_level": 10}
	)
	assert_eq(rows.size(), 1)
	assert_eq(str(rows[0]["name"]), "Alice")
	assert_eq(int(rows[0]["level"]), 17)
	assert_eq(str(rows[0]["role"]), "dps")
	assert_eq(str(rows[0]["guild"]), "Knights")
	assert_eq(str(rows[0]["zone"]), "Starter Vale")
	var ashmoor := Discovery.who(
		positions, {1: 17, 2: 9}, {1: "mage", 2: "warrior"}, {}, {}, {"zone": "ashmoor"}
	)
	assert_eq(ashmoor.size(), 1)
	assert_eq(str(ashmoor[0]["name"]), "Bob")


func test_note_is_single_line_and_bounded() -> void:
	assert_eq(
		Discovery.clean_note("  hello\nthere  "), "hello there", "newlines cannot forge board rows"
	)
	assert_eq(Discovery.clean_note("x".repeat(500)).length(), Discovery.NOTE_MAX)


# ---- T-755: the world server must not STORE a bbcode payload ------------------
#
# GuildPanel renders these notes into a bbcode_enabled label whose meta_clicked fires
# party_invite. The client escape is the real fix; this is the defence-in-depth half, and it
# STRIPS rather than rejects because clean_note has always been a silent sanitiser with no
# channel to report a refusal to the player.
func test_note_strips_bbcode_so_no_payload_is_ever_stored() -> void:
	assert_eq(
		Discovery.clean_note("[url=party|victim]free gold[/url]"),
		"url=party|victimfree gold/url",
		"the forged party-invite payload cannot survive into the board"
	)
	assert_eq(Discovery.clean_note("[color=red]pick me"), "color=redpick me", "no opening tag")
	assert_false(Discovery.clean_note("[b]x[/b]").contains("["), "no bracket survives, either way")
	assert_false(Discovery.clean_note("[b]x[/b]").contains("]"))


func test_note_stripping_leaves_ordinary_copy_alone() -> void:
	# A sanitiser nobody notices is the point — an honest note must round-trip untouched.
	var honest := "New to the game, happy to learn — EU evenings, 18+"
	assert_eq(Discovery.clean_note(honest), honest, "a normal note is unaffected")


func test_stripped_note_reaches_the_board_row() -> void:
	# The unit above proves the helper; this proves flag() actually routes through it, which is the
	# part a refactor could silently drop.
	var store := Discovery.new_store()
	Discovery.flag(store, 1, 5, "tank", "[url=party|victim]click[/url]")
	var rows := Discovery.board(store)
	assert_eq(rows.size(), 1)
	assert_false(str(rows[0]["note"]).contains("["), "the stored row carries no tag opener")


# T-477: mentor/mentee discovery is a pure opt-in signals board. Eligibility is decided from the
# injected authoritative level, and rows carry only server-projected role/zone plus a bounded note.
func test_mentorship_flags_enforce_level_eligibility_and_filter_each_side() -> void:
	var store := Discovery.new_mentorship_store()
	assert_true(
		bool(
			Discovery.flag_mentorship(store, 1, "mentor", 30, "tank", "Ashmoor", "Crypt runs")["ok"]
		)
	)
	assert_true(
		bool(
			(
				Discovery
				. flag_mentorship(store, 2, "mentee", 8, "heal", "Starter Vale", "Hale quests")["ok"]
			)
		)
	)
	assert_false(
		bool(
			Discovery.flag_mentorship(store, 3, "mentor", 8, "dps", "Starter Vale", "forged")["ok"]
		),
		"a newcomer cannot forge veteran eligibility",
	)
	var mentors := Discovery.mentorship_board(store, "mentor")
	var mentees := Discovery.mentorship_board(store, "mentee")
	assert_eq(mentors.size(), 1)
	assert_eq(int(mentors[0]["level"]), 30)
	assert_eq(str(mentors[0]["zone"]), "Ashmoor")
	assert_eq(mentees.size(), 1)
	assert_eq(str(mentees[0]["role"]), "heal")


func test_mentorship_flags_prune_party_join_and_level_out_of_range() -> void:
	var store := Discovery.new_mentorship_store()
	Discovery.flag_mentorship(store, 1, "mentor", 30, "tank", "Ashmoor", "")
	Discovery.flag_mentorship(store, 2, "mentee", 8, "dps", "Starter Vale", "")
	assert_eq(Discovery.prune_mentorship(store, {1: 30, 2: 8}, {2: 7}), [2])
	assert_eq(Discovery.prune_mentorship(store, {1: 10}, {}), [1])
	assert_eq(Discovery.mentorship_board(store).size(), 0)


func test_who_can_filter_server_held_mentor_flag() -> void:
	var positions := {
		1: {"username": "Mentor", "x": 0.0, "z": 0.0, "instance_id": 0},
		2: {"username": "Other", "x": 0.0, "z": 0.0, "instance_id": 0},
	}
	var mentor_store := Discovery.new_mentorship_store()
	Discovery.flag_mentorship(mentor_store, 1, "mentor", 30, "tank", "Starter Vale", "")
	var rows := Discovery.who(
		positions, {1: 30, 2: 30}, {1: "warrior", 2: "mage"}, {}, {}, {"mentor": true}, mentor_store
	)
	assert_eq(rows.size(), 1)
	assert_eq(str(rows[0]["name"]), "Mentor")
	assert_true(bool(rows[0]["mentor"]))
