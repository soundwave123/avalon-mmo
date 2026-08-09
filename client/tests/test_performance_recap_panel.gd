extends "res://addons/gut/test.gd"
# T-429: private SolidWindow recap — server-fed totals, own-history comparison, ability bars.

const RecapPanel = preload("res://scripts/ui/performance_recap_panel.gd")
const ReplyRouter = preload("res://scripts/net/reply_router.gd")
const ClientNet = preload("res://scripts/net/client_net.gd")

var _panel = null
var _sent: Array = []
var _router = null


func before_each() -> void:
	_sent = []
	_router = ReplyRouter.new()
	_panel = RecapPanel.new()
	add_child(_panel)
	await get_tree().process_frame
	_panel.setup(func(msg: Dictionary): _sent.append(msg), Callable(), _router)


func after_each() -> void:
	_panel.queue_free()


func _recap() -> Dictionary:
	return {
		"encounter_label": "Timber Wolf",
		"damage_done": 120,
		"damage_taken": 55,
		"healing_done": 30,
		"healing_taken": 18,
		"mitigation": 14,
		"interrupts": 2,
		"deaths": 1,
		"duration_s": 10.0,
		"dps": 12.0,
		"hps": 3.0,
		"comparison": {"runs": 3, "damage_pct": 8.3, "healing_pct": -4.0},
		"abilities":
		[
			{
				"id": 101,
				"name": "Heroic Strike",
				"uses": 4,
				"damage": 90,
				"healing": 0,
				"interrupts": 1
			},
			{"id": 301, "name": "Mend", "uses": 2, "damage": 0, "healing": 30, "interrupts": 0},
		],
	}


func test_is_solid_window_and_renders_all_private_totals() -> void:
	_panel.receive({"type": "performance_recap", "recap": _recap()})
	var frame: PanelContainer = _panel.get_node("PerformanceRecapFrame")
	assert_not_null(_panel.theme, "panel self-carries the shared UI theme")
	assert_eq(frame.theme_type_variation, &"SolidWindow")
	assert_true(_panel.visible, "post-encounter peer reply opens the recap")
	assert_true(_panel._title.text.contains("Timber Wolf"))
	var expected_parts := [
		"Damage  120 done / 55 taken",
		"Healing  30 done / 18 taken",
		"Mitigated  14",
		"Interrupts  2",
		"Deaths  1",
		"10.0s",
		"12.0 DPS",
		"3.0 HPS",
	]
	for expected in expected_parts:
		assert_true(_panel._summary.text.contains(expected), "summary includes %s" % expected)


func test_comparison_is_explicitly_against_own_average() -> void:
	_panel.receive({"type": "performance_recap", "recap": _recap()})
	assert_true(_panel._comparison.text.contains("+8.3% damage vs your 3-run average"))
	assert_true(_panel._comparison.text.contains("-4.0% healing vs your 3-run average"))
	assert_false(_panel._comparison.text.contains("rank"), "self mirror never frames a public rank")


func test_builds_one_contribution_bar_per_ability() -> void:
	_panel.receive({"type": "performance_recap", "recap": _recap()})
	assert_eq(_panel._ability_rows.size(), 2)
	assert_eq(_panel._ability_rows[0]["label"].text, "Heroic Strike — 4 uses — 90")
	assert_eq(_panel._ability_rows[0]["bar"].value, 90.0)
	assert_eq(_panel._ability_rows[1]["label"].text, "Mend — 2 uses — 30")
	assert_eq(_panel._ability_rows[1]["bar"].value, 30.0)


func test_open_sends_only_payload_free_self_read_and_no_share_control_exists() -> void:
	assert_false(_panel.visible)
	_panel.toggle()
	assert_eq(_sent, [{"type": "performance_recap_request"}])
	_panel.toggle()
	assert_eq(_sent.size(), 1, "closing sends nothing")
	var buttons: Array = _panel.find_children("*", "Button", true, false)
	assert_eq(buttons.size(), 0, "dark-pattern refusal: no broadcast/share/rank button")


func test_reply_router_opens_only_registered_private_reply() -> void:
	assert_true(_router.has_route("performance_recap"))
	var net = ClientNet.new()
	net.setup(func(_m): pass, {"pvp": func(data): _router.route(data)})
	net.handle_server_message({"type": "performance_recap", "recap": _recap()})
	assert_true(_panel.visible)
	assert_eq(_panel._last_recap["damage_done"], 120)
	assert_false(_router.has_route("performance_recap_public"))


# ---- T-571 (report #27): the recap yields z-order instead of blocking whatever opens next ----


func test_should_yield_only_when_showing_and_another_panel_opens() -> void:
	assert_true(RecapPanel.should_yield(true, true), "recap showing + other panel now visible")
	assert_false(RecapPanel.should_yield(false, true), "recap already closed — nothing to yield")
	assert_false(RecapPanel.should_yield(true, false), "the other panel closed, not opened")
	assert_false(RecapPanel.should_yield(false, false))


func test_watch_panels_hides_recap_when_a_watched_panel_becomes_visible() -> void:
	_panel.receive({"type": "performance_recap", "recap": _recap()})
	assert_true(_panel.visible, "recap is up first")
	var spellbook := Control.new()
	spellbook.visible = false  # Control.new() defaults to visible=true — start it closed
	add_child_autofree(spellbook)
	_panel.watch_panels([spellbook])
	spellbook.visible = true  # a real false->true transition, so visibility_changed fires
	assert_false(_panel.visible, "the recap stepped aside for the panel that just opened")


func test_watch_panels_does_not_hide_recap_when_a_watched_panel_closes() -> void:
	_panel.receive({"type": "performance_recap", "recap": _recap()})
	var spellbook := Control.new()
	spellbook.visible = true
	add_child_autofree(spellbook)
	_panel.watch_panels([spellbook])
	spellbook.visible = false
	assert_true(_panel.visible, "closing another panel is not a reason for the recap to hide")


func test_watch_panels_no_ops_when_recap_already_closed() -> void:
	assert_false(_panel.visible)
	var spellbook := Control.new()
	spellbook.visible = false
	add_child_autofree(spellbook)
	_panel.watch_panels([spellbook])
	spellbook.visible = true
	assert_false(_panel.visible, "still closed — nothing to yield")


# ---- #79: the recap auto-pops on EVERY kill, not just when the whole pull is over --------------


func test_autopop_gate_false_suppresses_the_auto_show() -> void:
	_panel.set_autopop_gate(func(): return false)  # e.g. a second hostile is still nearby
	_panel.receive({"type": "performance_recap", "recap": _recap()})
	assert_false(_panel.visible, "a mid-pull kill reply must not steal the screen")


func test_autopop_gate_still_caches_and_renders_the_data_while_suppressed() -> void:
	_panel.set_autopop_gate(func(): return false)
	_panel.receive({"type": "performance_recap", "recap": _recap()})
	# The comparison line only renders once _render() ran — proves the data updated even though the
	# panel stayed hidden, so a later R-press (toggle()) shows the FRESH numbers, not stale ones.
	assert_true(
		_panel._comparison.text.contains("3-run"), "the data rendered despite staying hidden"
	)


func test_autopop_gate_true_shows_normally() -> void:
	_panel.set_autopop_gate(func(): return true)  # e.g. no live hostile left nearby
	_panel.receive({"type": "performance_recap", "recap": _recap()})
	assert_true(_panel.visible, "the gate allowing it pops the recap as before")


func test_unset_autopop_gate_defaults_to_always_show() -> void:
	# No gate wired (headless tests / any caller that never calls set_autopop_gate) must keep the
	# pre-#79 behaviour — never silently regress a caller that doesn't know about the gate.
	_panel.receive({"type": "performance_recap", "recap": _recap()})
	assert_true(_panel.visible, "an unset gate never suppresses the auto-pop")


func test_autopop_gate_does_not_affect_manual_toggle() -> void:
	_panel.set_autopop_gate(func(): return false)
	_panel.toggle()  # R press — always on-demand, gate or no gate
	assert_true(_panel.visible, "a manual R-press always opens it regardless of the gate")


# ---- #78: mob nameplate bleed-through — the recap's fill must be FULLY opaque ------------------


func test_frame_fill_is_fully_opaque_not_the_shared_solidwindow_0_94() -> void:
	var frame: PanelContainer = _panel.get_node("PerformanceRecapFrame")
	var sb := frame.get_theme_stylebox("panel") as StyleBoxFlat
	assert_not_null(sb, "a real StyleBoxFlat fill, not an empty/no-op stylebox")
	assert_eq(
		sb.bg_color.a, 1.0, "opaque enough that a world-space nameplate can never show through"
	)


func test_frame_still_carries_the_solidwindow_border_treatment() -> void:
	# The opacity override must not throw away the rest of the SolidWindow look (border/corners).
	var frame: PanelContainer = _panel.get_node("PerformanceRecapFrame")
	var sb := frame.get_theme_stylebox("panel") as StyleBoxFlat
	var reference := UiTheme.window_stylebox()
	assert_eq(sb.border_color, reference.border_color)
	assert_eq(sb.border_width_left, reference.border_width_left)
	assert_eq(sb.corner_radius_top_left, reference.corner_radius_top_left)
