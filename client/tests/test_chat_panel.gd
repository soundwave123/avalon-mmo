extends "res://addons/gut/test.gd"
# T-361: ChatPanel — the focus gate (is_typing) that keeps WASD/hotkeys from firing while typing,
# the send path, and the receive/append + rejection rendering.

var _panel: ChatPanel = null
var _sent: Array = []


func before_each() -> void:
	_panel = ChatPanel.new()
	add_child(_panel)
	await get_tree().process_frame
	_sent = []
	_panel.setup(func(intent: Dictionary): _sent.append(intent))


func after_each() -> void:
	_panel.queue_free()


func test_starts_empty_and_not_typing() -> void:
	assert_eq(_panel.line_count(), 0)
	assert_false(_panel.is_typing(), "no keyboard focus until the input is opened")


func test_receive_appends_a_line() -> void:
	_panel.receive({"type": "chat", "channel": "say", "from": "Alice", "text": "hi there"})
	assert_eq(_panel.line_count(), 1)
	assert_true(_panel.get_text().contains("Alice"))
	assert_true(_panel.get_text().contains("hi there"))


func test_rejection_renders_as_system_notice() -> void:
	_panel.receive({"type": "chat_rejected", "reason": "rate_limited"})
	assert_eq(_panel.line_count(), 1)
	assert_true(_panel.get_text().contains("rate_limited"))


func test_submit_sends_on_active_channel_and_releases_focus() -> void:
	_panel._select_channel("party")
	_panel._on_submit("pull now")
	assert_eq(_sent.size(), 1, "submitting a non-empty line sends exactly once")
	assert_eq(str(_sent[0]["type"]), "chat", "a plain line is a chat intent")
	assert_eq(str(_sent[0]["channel"]), "party", "sends on the selected tab")
	assert_eq(str(_sent[0]["text"]), "pull now")
	assert_false(_panel.is_typing(), "focus returns to movement after sending")


func test_blank_submit_sends_nothing() -> void:
	_panel._on_submit("   ")
	assert_eq(_sent.size(), 0, "whitespace-only input is never sent")


func test_default_channel_is_say() -> void:
	_panel._on_submit("hello")
	assert_eq(str(_sent[0]["type"]), "chat")
	assert_eq(str(_sent[0]["channel"]), "say", "say is the default active tab")


# T-361 item 3: a "/wave"-style line is parsed into an emote INTENT (the client sends only the id;
# the server validates it). Case + trailing args are normalised; the active chat tab is irrelevant.
func test_slash_command_sends_emote_intent() -> void:
	_panel._select_channel("party")
	_panel._on_submit("/Wave at the crowd")
	assert_eq(_sent.size(), 1, "a slash line sends exactly one intent")
	assert_eq(str(_sent[0]["type"]), "emote", "a /slash line is an emote, not chat")
	assert_eq(str(_sent[0]["id"]), "wave", "the first word after / is the lowercased emote id")
	assert_false(_sent[0].has("channel"), "an emote carries no chat channel")


func test_emote_line_renders_in_history() -> void:
	_panel.receive({"type": "emote", "from": "Alice", "text": "Alice waves.", "clip": ""})
	assert_eq(_panel.line_count(), 1, "an emote action line is appended to the history")
	assert_true(_panel.get_text().contains("Alice waves."), "the server-resolved text is rendered")


# --- T-381: /duel commands route to duel intents (NOT emotes) --------------
func test_duel_challenge_sends_request_intent() -> void:
	_panel._on_submit("/duel Bob")
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["type"]), "duel_request", "/duel <name> is a duel_request, not an emote")
	assert_eq(str(_sent[0]["target"]), "Bob", "the target name is preserved (case intact)")


func test_duel_accept_decline_cancel_intents() -> void:
	_panel._on_submit("/duel accept")
	_panel._on_submit("/duel decline")
	_panel._on_submit("/duel cancel")
	assert_eq(_sent.size(), 3)
	assert_eq(str(_sent[0]["type"]), "duel_accept")
	assert_eq(str(_sent[1]["type"]), "duel_decline")
	assert_eq(str(_sent[2]["type"]), "duel_cancel")
	assert_false(_sent[0].has("target"), "a bare /duel accept carries no target")


func test_duel_system_line_renders_as_notice() -> void:
	_panel.receive({"type": "chat", "channel": "system", "from": "", "text": "Bob challenges you"})
	assert_eq(_panel.line_count(), 1, "a system-channel duel line is appended")
	assert_true(_panel.get_text().contains("Bob challenges you"), "the offer text renders")


# --- T-396: WORLD tab ships and routes exactly like the other channels ------
func test_world_tab_routes_channel_world() -> void:
	_panel._select_channel("world")
	_panel._on_submit("wtb iron sword")
	assert_eq(_sent.size(), 1)
	assert_eq(str(_sent[0]["type"]), "chat", "a world line is still a chat intent")
	assert_eq(str(_sent[0]["channel"]), "world", "the WORLD tab puts channel=world on the wire")
	assert_eq(str(_sent[0]["text"]), "wtb iron sword")


func test_world_is_an_available_channel() -> void:
	assert_true(ChatPanel.CHANNELS.has("world"), "the WORLD tab is shipped")


func test_help_tab_and_opt_out_intent() -> void:
	assert_true(ChatPanel.CHANNELS.has("help"), "newcomers have a dedicated help tab")
	_panel._select_channel("help")
	_panel._on_submit("Where is Drillmaster Hale?")
	assert_eq(str(_sent[0]["channel"]), "help")
	_panel._on_submit("/help off")
	assert_eq(_sent[1], {"type": "help_subscription", "subscribed": false})
	_panel._on_submit("/help on")
	assert_eq(_sent[2], {"type": "help_subscription", "subscribed": true})


func test_server_annotated_mentor_is_visible_in_help_chat() -> void:
	_panel.receive(
		{"type": "chat", "channel": "help", "from": "Alice", "text": "Need a hand?", "mentor": true}
	)
	assert_true(_panel.get_text().contains("Mentor"))
	assert_true(_panel.get_text().contains("Alice"))


# --- T-396: the input row exists only while typing -------------------------
func test_input_row_hidden_until_summoned() -> void:
	assert_false(_panel.input_visible(), "no permanently-drawn input box; hidden until Enter")
	var ev := InputEventKey.new()
	ev.keycode = KEY_ENTER
	ev.physical_keycode = KEY_ENTER  # T-761: the panel dispatches on the PHYSICAL code
	ev.pressed = true
	_panel._input(ev)
	assert_true(_panel.input_visible(), "Enter summons the input row")


func test_input_row_hidden_after_focus_lost() -> void:
	# T-756: this used to call _on_input_focus_exited() on a fresh panel and assert the input row
	# was hidden — but before_each's panel starts hidden, so the assertion held no matter what
	# (or whether) _on_input_focus_exited did anything. Gut the function body and it still
	# passed. Summon the row first so the assertion is about the DISMISSAL.
	var ev := InputEventKey.new()
	ev.keycode = KEY_ENTER
	ev.physical_keycode = KEY_ENTER  # T-761: the panel dispatches on the PHYSICAL code
	ev.pressed = true
	_panel._input(ev)
	assert_true(_panel.input_visible(), "precondition: Enter summoned the input row")

	_panel._on_input_focus_exited()
	assert_false(_panel.input_visible(), "dismissing typing hides the input row again")


# --- T-396: click-through when idle, interactive when focused/hovered -------
func test_idle_chat_is_click_through() -> void:
	assert_eq(
		_panel.history_mouse_filter(),
		Control.MOUSE_FILTER_IGNORE,
		"idle chat never eats a world click"
	)
	assert_eq(_panel.mouse_filter, Control.MOUSE_FILTER_IGNORE)


func test_focus_makes_chat_interactive() -> void:
	_panel._on_input_focus_entered()
	assert_eq(
		_panel.history_mouse_filter(),
		Control.MOUSE_FILTER_STOP,
		"an open input row restores normal filtering for reading/scrolling"
	)
	assert_eq(_panel.mouse_filter, Control.MOUSE_FILTER_STOP)
	_panel._on_input_focus_exited()
	assert_eq(
		_panel.history_mouse_filter(),
		Control.MOUSE_FILTER_IGNORE,
		"leaving focus returns to click-through"
	)


func test_hover_makes_chat_interactive() -> void:
	_panel._on_part_entered()
	assert_true(_panel.presence().is_interactive())
	assert_eq(_panel.history_mouse_filter(), Control.MOUSE_FILTER_STOP)
	_panel._on_part_exited()
	assert_false(_panel.presence().is_interactive(), "un-hovering returns to click-through")


# --- T-396: a new line resets the inactivity fade --------------------------
func test_new_line_resets_the_inactivity_fade() -> void:
	# Age the panel into the faded state, then prove a fresh line revives it.
	for i in range(int(ChatPresence.IDLE_FADE_DELAY) + 2):
		_panel.presence().tick(1.0)
	assert_false(_panel.presence().is_awake(), "silence fades the panel out")
	_panel.receive({"type": "chat", "channel": "say", "from": "Bob", "text": "back"})
	assert_true(_panel.presence().is_awake(), "a new line wakes the faded panel")
	assert_eq(_panel.presence().area_alpha, ChatPresence.AREA_AWAKE_ALPHA)


# --- T-607: CombatLog merges into this SAME surface (no second overlapping panel) ---------------


func test_bind_combat_log_renders_entries_in_history() -> void:
	var log := CombatLog.new()
	add_child(log)
	await get_tree().process_frame
	_panel.bind_combat_log(log)
	log.add_entry("You hit the wolf for 7.", Color.RED)
	assert_eq(_panel.line_count(), 1)
	assert_true(_panel.get_text().contains("You hit the wolf for 7."))
	log.queue_free()


func test_combat_line_and_chat_line_share_one_surface() -> void:
	# The merge means both a combat line and a chat line land in the SAME `_lines`/RichTextLabel —
	# there is no second panel/rect for either to hide behind or overlap.
	var log := CombatLog.new()
	add_child(log)
	await get_tree().process_frame
	_panel.bind_combat_log(log)
	log.add_entry("Out of range — target 4.0m away.", Color.RED)
	_panel.receive({"type": "chat", "channel": "say", "from": "Alice", "text": "watch my flank"})
	assert_eq(_panel.line_count(), 2, "both lines land in the one merged history")
	var text := _panel.get_text()
	assert_true(text.contains("Out of range"), "the combat line is present")
	assert_true(text.contains("watch my flank"), "the chat line is present")
	log.queue_free()


func test_combat_log_coalesce_updates_last_line_in_place() -> void:
	# T-556: a coalesced repeat rewrites the newest combat line's "(xN)" count instead of spamming
	# a fresh line, as long as nothing else was appended after it.
	var log := CombatLog.new()
	add_child(log)
	await get_tree().process_frame
	_panel.bind_combat_log(log)
	log.add_entry("Out of range.", Color.RED)
	log.add_entry("Out of range.", Color.RED)  # coalesces on the CombatLog side too
	assert_eq(_panel.line_count(), 1, "a repeat rewrites in place, it does not add a new line")
	assert_true(_panel.get_text().contains("(x2)"), "the coalesced count is visible")
	log.queue_free()


func test_combat_log_coalesce_never_clobbers_an_interleaved_chat_line() -> void:
	# If a chat line lands between a combat line and its coalesced repeat, the repeat must NOT
	# silently overwrite the chat line underneath it — it falls back to a fresh append instead.
	var log := CombatLog.new()
	add_child(log)
	await get_tree().process_frame
	_panel.bind_combat_log(log)
	log.add_entry("Out of range.", Color.RED)
	_panel.receive({"type": "chat", "channel": "say", "from": "Bob", "text": "incoming"})
	log.add_entry("Out of range.", Color.RED)  # would coalesce, but a chat line is now last
	assert_eq(_panel.line_count(), 3, "the chat line is preserved, not overwritten")
	assert_true(_panel.get_text().contains("incoming"), "the interleaved chat line survives intact")
	log.queue_free()


func test_combat_line_wakes_the_shared_presence_like_chat() -> void:
	# T-396 fade rules: a combat line must ride the SAME ChatPresence timer as a chat line (that's
	# the point of the merge — no more independent CombatLogPanel presence racing this one).
	var log := CombatLog.new()
	add_child(log)
	await get_tree().process_frame
	_panel.bind_combat_log(log)
	for i in range(int(ChatPresence.IDLE_FADE_DELAY) + 2):
		_panel.presence().tick(1.0)
	assert_false(_panel.presence().is_awake(), "silence fades the merged panel out")
	log.add_entry("A wolf hits you for 4.", Color.RED)
	assert_true(_panel.presence().is_awake(), "a combat line wakes the shared presence")
	log.queue_free()
