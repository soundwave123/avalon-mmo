class_name PerformanceRecapPanel
extends Control
# T-429: private post-encounter self mirror. Every number is rendered from the peer-only world
# reply; the client can request a refresh but cannot submit metrics, identity, comparison, or share.

const _PROXIMITY = preload("res://scripts/world/hostile_proximity.gd")
# #79: "still in a pull" radius for the autopop gate — generous enough to cover a multi-mob pull
# without false-suppressing on an unrelated wandering mob (a smaller cousin of RemoteEntitiesLayer's
# own 25m nameplate-visibility budget, LABEL_CULL_DISTANCE_M).
const AUTOPOP_HOSTILE_RANGE_M := 20.0

var _send: Callable = Callable()
var _is_typing: Callable = Callable()
# #79: main.gd wires this to "no live hostile nearby, or the player is dead" — a `performance_recap`
# reply arrives on EVERY mob kill (world/performance_recap_service.gd), not just when a pull is
# fully over, so auto-popping unconditionally covered the screen mid-fight against a second hostile.
# Empty (unset) means "always auto-pop" (headless tests / no gate wired) — the pre-#79 behaviour.
var _autopop_gate: Callable = Callable()
var _title: Label = null
var _summary: Label = null
var _comparison: Label = null
var _abilities: VBoxContainer = null
var _ability_rows: Array = []  # test/readback: [{label:Label, bar:ProgressBar}]
var _last_recap: Dictionary = {}


func _ready() -> void:
	name = "PerformanceRecapPanel"  # T-480: self-named (main.gd mounts routed panels generically)
	# T-522: the Defeat recap auto-surfaces on death; without this it stayed up after respawn until
	# the player found the R toggle (playtest #9 "the death menu doesn't disappear until you relog").
	# DeathPresentation.begin_respawn() dismisses this group on the local respawn.
	add_to_group("hide_on_local_respawn")
	visible = false
	theme = UiTheme.build()
	# T-533: explicit centre anchors (never set_anchors_preset — the 4.7 container-collapse trap). The
	# recap holds screen centre; death_presentation.gd stacks the "You died." headline above and the
	# durability toast + respawn cue below this ±140 band so neither collides with the recap's fill.
	# T-554: trimmed from ±260 to ±200 so the headline above it clears the top compass at the min
	# supported 1280x720. T-634: trimmed again to ±140 — the toast+cue stack BELOW this band still
	# has to clear the ActionBar hotbar's top edge (y=580) too, and ±200 left only 20px for both
	# lines (their real rendered height, at these font sizes, is ~54px combined). The ability
	# breakdown scrolls, so the shorter panel loses no information. Keep this in sync with
	# death_presentation.gd's _RECAP_HALF_HEIGHT.
	custom_minimum_size = Vector2(480, 280)
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -240.0
	offset_right = 240.0
	offset_top = -140.0
	offset_bottom = 140.0

	var frame := PanelContainer.new()
	frame.name = "PerformanceRecapFrame"
	frame.theme_type_variation = "SolidWindow"
	# #78: SolidWindow's default fill (0.94 alpha) let a world-space mob nameplate ghost through —
	# this window auto-pops centered on screen mid-combat, squarely over where the nameplate of the
	# mob just fought usually sits. Override with a FULLY opaque fill (still the SolidWindow border/
	# shadow/corner treatment, same theme_type_variation for everything else that resolves off it).
	frame.add_theme_stylebox_override("panel", UiTheme.opaque_window_stylebox())
	frame.anchor_left = 0.0
	frame.anchor_top = 0.0
	frame.anchor_right = 1.0
	frame.anchor_bottom = 1.0
	frame.offset_left = 0.0
	frame.offset_top = 0.0
	frame.offset_right = 0.0
	frame.offset_bottom = 0.0
	add_child(frame)
	var column := VBoxContainer.new()
	frame.add_child(column)
	_title = Label.new()
	_title.name = "RecapTitle"
	_title.text = "Performance Recap  (R)"
	column.add_child(_title)
	_comparison = Label.new()
	_comparison.name = "SelfComparison"
	_comparison.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_comparison)
	_summary = Label.new()
	_summary.name = "RecapSummary"
	column.add_child(_summary)
	var breakdown := Label.new()
	breakdown.text = "Ability Breakdown"
	column.add_child(breakdown)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	_abilities = VBoxContainer.new()
	_abilities.name = "AbilityRows"
	_abilities.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_abilities)
	# T-748: unlike every other window in the sweep, the player never SUMMONS this one — it pops
	# itself up dead-centre screen after a kill (#79's gate only holds it back while a hostile is
	# still close). An unsummoned window must not take the player's clicks, so the whole 480x280
	# box is click-through (nothing in it is clickable) except the ability-breakdown scroll, which
	# keeps STOP so the wheel still scrolls the rows. R / Esc / respawn still dismiss it.
	UiTheme.set_mouse_filter_deep(self)
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_render()


# main.gd: build + wire the panel in one call (the CharacterSheetPanel/QuestOfferPanel.mount idiom
# — main.gd sits at its 1000-line cap). Self-named in _ready() above, so no name assignment here.
static func mount(
	hud: Node, send: Callable, is_typing: Callable, reply_router
) -> PerformanceRecapPanel:
	var panel := PerformanceRecapPanel.new()
	hud.add_child(panel)
	panel.setup(send, is_typing, reply_router)
	return panel


func setup(send: Callable, is_typing: Callable = Callable(), reply_router = null) -> void:
	_send = send
	_is_typing = is_typing
	if reply_router != null:
		reply_router.register("performance_recap", func(data: Dictionary): receive(data))


# #79: main.gd wires this AFTER setup() (it needs remote_entities/local_player/death_presentation,
# which don't exist yet at this panel's mount time). `gate` should return true when it's fine to
# auto-pop right now — see wire_autopop_gate() below, the one-call idiom main.gd actually uses.
func set_autopop_gate(gate: Callable) -> void:
	_autopop_gate = gate


# #79: mount()-idiom single call (main.gd sits at its 1000-line cap) — wires the gate straight off
# main.gd's own member vars via get(), so it always reads the CURRENT remote_entities/local_player/
# death_presentation at call time (local_player in particular is still null when main.gd wires this,
# ahead of _spawn_local_player()).
static func wire_autopop_gate(panel: PerformanceRecapPanel, main: Node) -> void:
	panel.set_autopop_gate(
		func():
			return is_safe_to_autopop(
				main.get("remote_entities"),
				main.get("local_player"),
				main.get("death_presentation")
			)
	)


# Pure predicate (unit-tested without a live tree/closures): safe to auto-pop when the player is
# dead (input already disabled; the recap is the useful thing to look at right then) or when no
# live hostile remains within AUTOPOP_HOSTILE_RANGE_M of them.
static func is_safe_to_autopop(remote_entities, local_player, death_presentation) -> bool:
	if death_presentation != null and death_presentation.is_input_disabled():
		return true
	if local_player == null or remote_entities == null:
		return true  # nothing to check against yet — never suppress on a startup race
	var entities: Dictionary = remote_entities.get("_entities")
	return not _PROXIMITY.has_live_hostile_nearby(
		entities, local_player.global_position, AUTOPOP_HOSTILE_RANGE_M
	)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if KeyRegistry.event_code(event as InputEventKey) != KEY_R:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing.is_valid() and bool(_is_typing.call()):
		return
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible and _send.is_valid():
		_send.call({"type": "performance_recap_request"})


# T-571 (report #27): the recap only ever closed on R or death-respawn, so it stayed up
# indefinitely and out-z-ordered whatever the player opened next (e.g. Spellbook covered by the
# recap on top). Watching each interactive panel's visibility lets the recap step aside the
# instant one opens, with no panel needing to know the recap exists.
func watch_panels(panels: Array) -> void:
	for p in panels:
		if p is Control:
			(p as Control).visibility_changed.connect(_on_watched_panel_shown.bind(p as Control))


func _on_watched_panel_shown(panel: Control) -> void:
	if should_yield(visible, panel.visible):
		visible = false


# Pure predicate (unit-tested without a live tree): the recap yields exactly when it is currently
# showing and the panel whose visibility just changed is now on screen.
static func should_yield(recap_visible: bool, other_panel_visible: bool) -> bool:
	return recap_visible and other_panel_visible


func receive(data: Dictionary) -> void:
	if str(data.get("type", "")) != "performance_recap":
		return
	var value: Variant = data.get("recap", {})
	if not value is Dictionary:
		return
	_last_recap = (value as Dictionary).duplicate(true)
	_render()
	# #79: a reply arrives on EVERY kill, not just when the whole pull is over — auto-pop only when
	# the gate says it's safe to (no live hostile still nearby, or the player is dead and can't act
	# anyway). The data is always cached + re-rendered above, so R still shows the latest numbers
	# even when the auto-pop is deferred.
	if _autopop_gate.is_valid() and not bool(_autopop_gate.call()):
		return
	visible = true  # post-encounter peer reply surfaces the private mirror immediately


func _render() -> void:
	if _summary == null:
		return
	var label := str(_last_recap.get("encounter_label", "No combat recorded"))
	_title.text = "Performance Recap — %s  (R)" % label
	_summary.text = (
		(
			"Damage  %d done / %d taken\n"
			+ "Healing  %d done / %d taken\n"
			+ "Mitigated  %d    Interrupts  %d    Deaths  %d\n"
			+ "%.1fs    %.1f DPS    %.1f HPS"
		)
		% [
			int(_last_recap.get("damage_done", 0)),
			int(_last_recap.get("damage_taken", 0)),
			int(_last_recap.get("healing_done", 0)),
			int(_last_recap.get("healing_taken", 0)),
			int(_last_recap.get("mitigation", 0)),
			int(_last_recap.get("interrupts", 0)),
			int(_last_recap.get("deaths", 0)),
			float(_last_recap.get("duration_s", 0.0)),
			float(_last_recap.get("dps", 0.0)),
			float(_last_recap.get("hps", 0.0)),
		]
	)
	_render_comparison(_last_recap.get("comparison", {}))
	_render_abilities(_last_recap.get("abilities", []))


func _render_comparison(value: Variant) -> void:
	var comparison: Dictionary = value if value is Dictionary else {}
	var runs := int(comparison.get("runs", 0))
	if runs <= 0:
		_comparison.text = "First recorded run — your personal baseline starts here."
		return
	var lines: Array[String] = []
	if comparison.has("damage_pct"):
		lines.append(
			(
				"%s damage vs your %d-run average"
				% [_signed_pct(float(comparison["damage_pct"])), runs]
			)
		)
	if comparison.has("healing_pct"):
		lines.append(
			(
				"%s healing vs your %d-run average"
				% [_signed_pct(float(comparison["healing_pct"])), runs]
			)
		)
	_comparison.text = (
		"  •  ".join(lines) if not lines.is_empty() else "Your %d-run personal history" % runs
	)


func _render_abilities(value: Variant) -> void:
	for child in _abilities.get_children():
		child.queue_free()
	_ability_rows.clear()
	var rows: Array = value if value is Array else []
	var largest := 1
	for row: Dictionary in rows:
		largest = maxi(largest, int(row.get("damage", 0)) + int(row.get("healing", 0)))
	for row: Dictionary in rows:
		var contribution := int(row.get("damage", 0)) + int(row.get("healing", 0))
		var box := VBoxContainer.new()
		var text := Label.new()
		text.text = (
			"%s — %d uses — %d"
			% [str(row.get("name", "Ability")), int(row.get("uses", 0)), contribution]
		)
		box.add_child(text)
		var bar := ProgressBar.new()
		bar.show_percentage = false
		bar.max_value = largest
		bar.value = contribution
		box.add_child(bar)
		_abilities.add_child(box)
		_ability_rows.append({"label": text, "bar": bar})
	if rows.is_empty():
		var empty := Label.new()
		empty.text = "No abilities recorded."
		_abilities.add_child(empty)


func _signed_pct(value: float) -> String:
	return "%s%.1f%%" % ["+" if value >= 0.0 else "", value]
