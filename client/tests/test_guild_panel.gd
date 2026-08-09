extends "res://addons/gut/test.gd"
# T-362: GuildPanel — server-fed roster render, the invite/accept flow, and desire-only sends. The
# panel never grants itself anything: every button/link emits an INTENT the server re-validates.

var _panel: GuildPanel = null
var _sent: Array = []


func before_each() -> void:
	_panel = GuildPanel.new()
	add_child(_panel)
	await get_tree().process_frame
	_sent = []
	_panel.setup(func(msg): _sent.append(msg))


func after_each() -> void:
	_panel.queue_free()


func _roster(with_leader: bool = true) -> Dictionary:
	return {
		"type": "guild_roster",
		"guild_id": 7,
		"guild_name": "Knights",
		"you": "Alice",  # the viewer is the leader
		"members":
		[
			{
				"name": "Alice",
				"rank": 0,
				"rank_name": "Leader",
				"is_leader": with_leader,
				"online": true
			},
			{"name": "Bob", "rank": 2, "rank_name": "Member", "is_leader": false, "online": false},
		],
	}


func test_renders_roster_with_ranks_and_presence() -> void:
	_panel.receive(_roster())
	var t := _panel.body_text()
	assert_true(t.contains("Knights"))
	assert_true(t.contains("Alice"))
	assert_true(t.contains("Leader"))
	assert_true(t.contains("Bob"))
	assert_true(t.contains("Member"))


func test_guildless_state_prompts_create() -> void:
	assert_true(_panel.body_text().contains("not in a guild"))
	_panel._name_box.text = "Round Table"
	_panel._named("guild_create")
	assert_eq(str(_sent[0]["type"]), "guild_create")
	assert_eq(str(_sent[0]["name"]), "Round Table")
	assert_eq(_panel._name_box.text, "", "name box clears after founding")


func test_invite_prompt_offers_accept_and_decline() -> void:
	_panel.receive({"type": "guild_invite", "from": "Alice", "guild_name": "Knights"})
	assert_true(_panel.visible, "an invite pops the panel open")
	assert_true(_panel.body_text().contains("[url=accept]"))
	assert_true(_panel.body_text().contains("[url=decline]"))
	_panel._on_meta("accept")
	assert_eq(str(_sent[0]["type"]), "guild_accept")


func test_leader_sees_management_links_and_kicks_by_name() -> void:
	_panel.receive(_roster())
	# Leader (rank 0) sees kick/promote on non-leader Bob, but NOT on themselves.
	assert_true(_panel.body_text().contains("[url=kick|Bob]"))
	assert_false(
		_panel.body_text().contains("[url=kick|Alice]"), "no management link on the leader"
	)
	_panel._on_meta("kick|Bob")
	assert_eq(str(_sent[0]["type"]), "guild_kick")
	assert_eq(str(_sent[0]["name"]), "Bob")
	_panel._on_meta("promote|Bob")
	assert_eq(str(_sent[1]["type"]), "guild_promote")


func test_disband_notice_clears_the_panel() -> void:
	_panel.receive(_roster())
	_panel.receive({"type": "guild_disbanded"})
	assert_true(_panel.body_text().contains("not in a guild"), "roster cleared on disband")


func test_result_rejection_is_status_only() -> void:
	_panel.receive(_roster())
	_panel.receive({"type": "guild_result", "ok": false, "reason": "name_taken"})
	# The roster stays rendered; the rejection surfaces as status, not a roster wipe.
	assert_true(_panel.body_text().contains("Knights"))


func test_invite_by_name_and_leave_send_desires() -> void:
	_panel.receive(_roster())
	_panel._name_box.text = "Carol"
	_panel._named("guild_invite")
	assert_eq(str(_sent[0]["type"]), "guild_invite")
	assert_eq(str(_sent[0]["name"]), "Carol")


# T-451: guildless discovery is visible and remains desire-only. Clicking a listing reuses the
# normal T-362 invite intent; there is deliberately no auto-join/auto-match button.
func test_renders_open_guilds_seekers_and_who_truth() -> void:
	(
		_panel
		. receive(
			{
				"type": "guild_discovery",
				"guilds": [{"name": "Knights", "blurb": "New players welcome", "members": 4}],
			}
		)
	)
	assert_true(_panel.body_text().contains("New players welcome"))
	(
		_panel
		. receive(
			{
				"type": "guild_seek_board",
				"players": [{"name": "Bob", "level": 12, "role": "tank", "note": "Weekends"}],
			}
		)
	)
	assert_true(_panel.body_text().contains("Bob"))
	assert_true(_panel.body_text().contains("Weekends"))
	(
		_panel
		. receive(
			{
				"type": "guild_who",
				"players":
				[{"name": "Carol", "level": 18, "role": "heal", "zone": "Ashmoor", "guild": ""}],
			}
		)
	)
	assert_true(_panel.body_text().contains("Ashmoor"))


func test_discovery_controls_emit_only_desires() -> void:
	_panel._request_discovery("guild_browse")
	_panel._request_discovery("guild_seek_list")
	_panel._request_discovery("player_who")
	assert_eq(str(_sent[0]["type"]), "guild_browse")
	assert_eq(str(_sent[1]["type"]), "guild_seek_list")
	assert_eq(str(_sent[2]["type"]), "player_who")
	_panel._note_box.text = "Casual quests"
	_panel._seek()
	assert_eq(_sent[3], {"type": "guild_seek", "note": "Casual quests"})
	assert_false(_sent[3].has("level"), "client never claims seeker level")
	assert_false(_sent[3].has("role"), "client never claims seeker role")


func test_recruitment_edit_and_seeker_invite_are_intents() -> void:
	_panel.receive(_roster())
	_panel._blurb_box.text = "Friendly and helpful"
	_panel._open_check.button_pressed = true
	_panel._set_recruitment()
	assert_eq(str(_sent[0]["type"]), "guild_set_recruitment")
	assert_true(bool(_sent[0]["open"]))
	_panel._on_meta("invite|Bob")
	assert_eq(_sent[1], {"type": "guild_invite", "name": "Bob"})


# T-477: the existing discovery window exposes opt-in mentorship signals and reuses party invite.
func test_mentor_board_renders_and_invites_through_normal_party_path() -> void:
	(
		_panel
		. receive(
			{
				"type": "mentor_board",
				"players":
				[
					{
						"name": "Bob",
						"kind": "mentor",
						"level": 30,
						"role": "tank",
						"zone": "Ashmoor",
						"note": "Crypt"
					}
				],
			}
		)
	)
	assert_true(_panel.body_text().contains("Available Mentors"))
	assert_true(_panel.body_text().contains("Bob"))
	assert_true(_panel.body_text().contains("Ashmoor"))
	_panel._on_meta("party|Bob")
	assert_eq(_sent[0], {"type": "party_invite", "target": "Bob"})


func test_mentor_controls_send_desire_without_level_role_or_identity() -> void:
	_panel._note_box.text = "Starter quests"
	_panel._mentor_flag("mentor")
	_panel._request_mentors("mentee")
	assert_eq(_sent[0], {"type": "mentor_flag", "kind": "mentor", "note": "Starter quests"})
	assert_false(_sent[0].has("level"))
	assert_false(_sent[0].has("role"))
	assert_false(_sent[0].has("name"))
	assert_eq(_sent[1], {"type": "mentor_list", "kind": "mentee"})


# ---- T-653 (#74): LineEdit focus trap softlocked ALL world hotkeys; no Close affordance ----


func _escape_key() -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	return ev


func test_escape_releases_focus_and_closes_the_panel_when_a_line_edit_is_focused() -> void:
	_panel.visible = true
	_panel._blurb_box.grab_focus()
	await get_tree().process_frame
	assert_true(_panel._blurb_box.has_focus())
	_panel._input(_escape_key())
	assert_false(_panel.visible, "Esc closed the panel instead of leaving it stuck open")
	assert_false(_panel._blurb_box.has_focus(), "Esc also released the trapped LineEdit's focus")


func test_escape_without_own_focus_leaves_the_panel_to_the_global_esc_gate() -> void:
	# No LineEdit focused here (this panel's own local branch only fires for its own trap case) —
	# main._handle_escape via _panel_set membership is what closes it in that path.
	_panel.visible = true
	_panel._input(_escape_key())
	assert_true(_panel.visible, "leaves the ordinary Esc-close path to main._handle_escape")


func test_escape_while_another_panels_field_is_focused_does_not_steal_it() -> void:
	# A stand-in LineEdit belonging to some OTHER panel holds real viewport focus; GuildPanel must
	# not react to Esc meant for it (e.g. chat mid-typing) just because it happens to be visible.
	var foreign := LineEdit.new()
	add_child(foreign)
	foreign.grab_focus()
	await get_tree().process_frame
	_panel.visible = true
	_panel._input(_escape_key())
	assert_true(_panel.visible, "GuildPanel does not close on Esc owned by an unrelated field")
	assert_true(foreign.has_focus(), "the foreign field's focus is untouched")
	foreign.queue_free()


func test_button_click_releases_focus_even_though_the_button_is_focus_none() -> void:
	_panel.visible = true
	_panel._name_box.grab_focus()
	await get_tree().process_frame
	assert_true(_panel._name_box.has_focus())
	var who_button := _panel.find_child("Who", true, false) as Button
	assert_not_null(who_button, "the Who button is discoverable by name")
	who_button.pressed.emit()
	assert_false(
		_panel._name_box.has_focus(),
		"clicking a FOCUS_NONE button still drops the trapped LineEdit's focus"
	)
	assert_eq(str(_sent[0]["type"]), "player_who", "the button's own action still ran")


func test_unhandled_world_click_releases_focus() -> void:
	# A click that reaches _unhandled_input missed every GUI control — i.e. it landed in the 3D
	# world (report #74's repro: clicking at 300,300 never released the trapped LineEdit).
	_panel.visible = true
	_panel._name_box.grab_focus()
	await get_tree().process_frame
	assert_true(_panel._name_box.has_focus())
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	_panel._unhandled_input(click)
	assert_false(_panel._name_box.has_focus(), "a world click drops the trapped LineEdit's focus")


# ---- T-653 (#74): button-row overflow at 1280px ("Mentees" truncated to "Mente", etc.) ----


func test_mentor_and_discover_row_buttons_keep_their_full_label_width_at_1280p() -> void:
	var root := Control.new()
	root.size = Vector2(1280, 720)
	add_child_autofree(root)
	_panel.get_parent().remove_child(_panel)
	root.add_child(_panel)
	_panel.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	for label in ["Mentees", "Seek Mentor", "Publish", "Seekers"]:
		var b := _panel.find_child(label.replace(" ", ""), true, false) as Button
		assert_not_null(b, "%s button exists" % label)
		assert_true(
			b.size.x >= b.get_minimum_size().x - 0.5,
			(
				"%s kept its full label width (%.1f >= %.1f) instead of being squeezed"
				% [label, b.size.x, b.get_minimum_size().x]
			)
		)
	# Restore normal ownership so after_each's plain _panel.queue_free() (shared by every other
	# test in this file) doesn't race root's add_child_autofree cascade-free of the same node.
	root.remove_child(_panel)
	add_child(_panel)
