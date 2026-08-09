extends GutTest

# T-401: the PvP panel's state math + honest-economy rendering. The pure helpers (next_tier_index,
# unlocked_titles, _result_notice) are tested without instantiating the Control; the render path is
# tested by feeding a server tracks reply and asserting the panel echoes THOSE costs verbatim — i.e.
# it renders from the server's published data, never from numbers baked into the UI. (The values are
# enforced against data/pvp_rewards.json server-side in the master suite, where that file lives.)

const PvpPanel = preload("res://scripts/ui/pvp_panel.gd")


func test_next_tier_index_walks_then_completes() -> void:
	var track := {"tiers": [{"cost": 100}, {"cost": 250}, {"cost": 400}], "tier": -1}
	assert_eq(PvpPanel.next_tier_index(track), 0, "nothing bought → next is tier 0")
	track["tier"] = 1
	assert_eq(PvpPanel.next_tier_index(track), 2, "tier 1 bought → next is tier 2")
	track["tier"] = 2
	assert_eq(PvpPanel.next_tier_index(track), -1, "last tier bought → track complete (-1)")


func test_unlocked_titles_only_lists_owned_title_tiers() -> void:
	# gaslight_regalia: tiers skin, skin, title:Gaslight Duelist (index 2). Owning tier 1 means the
	# title (tier 2) is NOT yet unlocked; owning tier 2 unlocks it.
	var tracks := [
		{
			"id": "gaslight_regalia",
			"tiers":
			[
				{"unlock": "skin_gaslight_coat"},
				{"unlock": "skin_gaslight_hat"},
				{"unlock": "title:Gaslight Duelist"},
			],
			"tier": 1,
		}
	]
	assert_eq(PvpPanel.unlocked_titles(tracks), [], "an unbought title tier is never wearable")
	(tracks[0] as Dictionary)["tier"] = 2
	assert_eq(
		PvpPanel.unlocked_titles(tracks),
		["title:Gaslight Duelist"],
		"buying the title tier makes exactly that title wearable"
	)


func test_unlocked_titles_skips_non_title_unlocks() -> void:
	var tracks := [{"tiers": [{"unlock": "skin_vale_wolf_cloak"}], "tier": 0}]
	assert_eq(PvpPanel.unlocked_titles(tracks), [], "a skin unlock is not a title")


func test_result_notice_confirms_and_rejects() -> void:
	assert_eq(
		PvpPanel._result_notice({"ok": true, "title": "title:Wolf of the Vale"}),
		"Now wearing: Wolf of the Vale",
		"a set confirmation strips the title: prefix for display"
	)
	assert_eq(
		PvpPanel._result_notice({"ok": true, "title": ""}),
		"Title cleared.",
		"empty title = cleared"
	)
	assert_eq(
		PvpPanel._result_notice({"ok": false, "reason": "not_unlocked"}),
		"Rejected: not_unlocked",
		"a fail-closed rejection surfaces the server reason"
	)


func test_panel_renders_the_server_supplied_costs_verbatim() -> void:
	# The panel must render whatever costs the server SENDS — proving the numbers come from data, not
	# from the UI. Distinctive costs (137/911) would never appear unless echoed from the reply.
	var tracks := [
		{
			"id": "test_track",
			"name": "Test Regalia",
			"tiers":
			[
				{"cost": 137, "unlock": "skin_x", "rarity": "uncommon"},
				{"cost": 911, "unlock": "title:Test Duelist", "rarity": "rare"},
			],
			"tier": -1,
		}
	]
	var panel = PvpPanel.new()
	add_child_autofree(panel)
	(
		panel
		. receive(
			{
				"type": "pvp_rating",
				"ranked": true,
				"honor": 500,
				"rating": {"rating": 1180, "tier": "Silver", "wins": 4, "losses": 2},
			}
		)
	)
	panel.receive({"type": "pvp_tracks", "tracks": tracks, "honor": 500, "active": ""})
	var body := panel.body_text()
	assert_string_contains(body, "Honor")
	assert_string_contains(body, "500", "the honor balance renders from the reply")
	assert_string_contains(body, "1180", "the rating renders from the reply")
	assert_string_contains(body, "Silver", "the tier renders from the reply")
	assert_string_contains(body, "Test Regalia")
	assert_string_contains(body, "137", "the server-supplied tier cost renders verbatim")
	assert_string_contains(
		body, "911", "every published tier cost renders, not just the buyable one"
	)


func test_leaderboard_name_survives_bracket_injection_at_render() -> void:
	# T-599 sibling hole: the Leaderboard/Honor section renders a SERVER-SUPPLIED player name
	# (_render_board) directly into bbcode. An unescaped "[" can spell a real tag (e.g. "[img]") that
	# a bbcode-enabled RichTextLabel treats as consuming everything after it — same failure mode as
	# the duel-result chat line (ChatFormatter), just on a different surface.
	var panel = PvpPanel.new()
	add_child_autofree(panel)
	(
		panel
		. receive(
			{
				"type": "pvp_leaderboard",
				"entries": [{"rank": 1, "name": "pl[img]ay7b", "rating": 1500, "tier": "Gold"}],
			}
		)
	)
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	add_child_autofree(rtl)
	rtl.text = panel.body_text()
	var parsed := rtl.get_parsed_text()
	assert_string_contains(
		parsed, "ay7b", "the tail of a bracket-hostile leaderboard name must not be swallowed"
	)
	assert_string_contains(parsed, "Gold", "the rest of the leaderboard row must not be swallowed")


func test_open_requests_the_full_state() -> void:
	var sent: Array = []
	var panel = PvpPanel.new()
	add_child_autofree(panel)
	panel.setup(func(m): sent.append(m), func(): return false, null)
	panel.toggle()  # open
	var types: Array = []
	for m in sent:
		types.append(str(m.get("type", "")))
	assert_true(types.has("pvp_rating"), "open pulls the caller's rating")
	assert_true(types.has("pvp_leaderboard"), "open pulls the leaderboard")
	assert_true(types.has("pvp_tracks"), "open pulls the reward tracks")


func test_meta_actions_emit_the_right_intents() -> void:
	var sent: Array = []
	var panel = PvpPanel.new()
	add_child_autofree(panel)
	panel.setup(func(m): sent.append(m), func(): return false, null)
	sent.clear()
	panel._on_meta("activate|wolf_of_the_vale")
	panel._on_meta("spend")
	panel._on_meta("title|title:Wolf of the Vale")
	panel._on_meta("title|")  # clear
	assert_eq(sent[0], {"type": "pvp_tracks", "action": "activate", "track": "wolf_of_the_vale"})
	assert_eq(sent[1], {"type": "pvp_tracks", "action": "spend"})
	assert_eq(sent[2], {"type": "pvp_set_title", "title": "title:Wolf of the Vale"})
	assert_eq(sent[3], {"type": "pvp_set_title", "title": ""}, "clear sends an empty title")
