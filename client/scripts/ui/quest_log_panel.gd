class_name QuestLogPanel
# T-038 / T-422d: Quest log UI — a modern, scrollable card list grouped by state (Active /
# Completed). Each quest is a titled card; each objective a labelled row with a real PROGRESS BAR
# (current/required) and a ✓ when met; a per-quest action button (turn in / abandon) emits the same
# intent metas the old [url] links did, so PanelActions + main.gd wiring is unchanged.
#
# Programmatic Control (no .tscn). Added under the HUD CanvasLayer by client/main.gd; fed by the
# network layer's `quest_log` message (render(quests)) and targeted `quest_delta` (apply_delta).
# Headless-testable via get_text() (a plain summary), get_quest_count(), get_action_metas().
#
# View-model (per quest) — the contract the world's enrich_quest_log produces:
#   { "quest_id", "title", "state": active|complete|abandoned,
#     "objectives": [ { "desc", "current": int, "required": int } ] }

extends Control

signal action_selected(meta: String)  # T-056: a clicked action button (turn_in / abandon)
signal objectives_changed(model: Array)  # T-461: feed the always-on HUD objective tracker

# state -> {header, hex} display config; also defines render order.
# Abandoned is intentionally absent: abandoning DELETES the quest (it must never linger in the log).
const _GROUPS := [
	{"state": "active", "header": "Active", "hex": "ffffff"},
	{"state": "complete", "header": "Completed", "hex": "66ff66"},
]

# T-621: quest difficulty band (server-computed `difficulty`) -> title colour. The colours ARE the
# pacing UI — a red title is above your level, grey is trivial. Only ACTIVE quests are tinted (a
# completed quest keeps the green "Completed" colour). Bands: content/quest_difficulty.gd.
const _DIFFICULTY_HEX := {
	"red": "ff4040",
	"orange": "ff8040",
	"yellow": "ffd030",
	"green": "40c040",
	"grey": "9d9d9d",
}
# T-621: the server-enforced active-quest cap (quest_state_machine.MAX_ACTIVE_QUESTS) — shown in the
# title as "(n/20)" so a player can see the log filling before the accept refusal ever fires.
const LOG_CAP := 20

var _list: VBoxContainer = null
var _count: int = 0
var _quests: Array = []  # T-058: last rendered list — the delta path upserts into it
var _summary: String = ""  # headless-test text mirror of what the cards show
var _action_metas: Array[String] = []  # metas of the action buttons currently rendered


func _ready() -> void:
	# EXPLICIT anchors (never set_anchors_preset — the 4.7 HUD-blank trap): a fixed panel on the LEFT.
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 1.0
	offset_left = 16.0
	offset_right = 376.0
	# T-608: was a hardcoded 56.0, which sat 34px INSIDE VitalsFrame's occupied band (bottom edge
	# y=116 incl. the auto-attack pip) — the "Rage 0/100" bar bled through the panel's top corner.
	# HudSafeZone is the shared constant now (see hud_safe_zone.gd for the full rationale).
	offset_top = HudSafeZone.PANEL_SAFE_TOP
	offset_bottom = -56.0
	visible = false  # toggled open with L
	theme = UiTheme.build()  # T-400: SolidWindow variation resolves off the shared theme
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	add_child(frame)
	# EXPLICIT anchors on the frame too, AFTER add_child (inventory_panel lesson: the preset call's
	# offset recompute collapses containers to 17x16 stubs).
	frame.anchor_left = 0.0
	frame.anchor_top = 0.0
	frame.anchor_right = 1.0
	frame.anchor_bottom = 1.0
	frame.offset_left = 0.0
	frame.offset_top = 0.0
	frame.offset_right = 0.0
	frame.offset_bottom = 0.0
	# Internal scroll caps the window to 720p (no overflow); a plain VBox holds the cards (NOT an RTL,
	# which once collapsed to zero size inside a ScrollContainer — settings_panel/inventory lesson).
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(scroll)
	_list = VBoxContainer.new()
	_list.name = "List"
	_list.custom_minimum_size = Vector2(332.0, 0.0)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	render([])


# quests: Array of view-model entries (see header). Rebuilds the grouped card list.
func render(quests: Array) -> void:
	_quests = quests.duplicate(true)  # T-058: deltas edit this snapshot
	_count = quests.size()
	_action_metas.clear()
	for child in _list.get_children():
		child.queue_free()
	var active_count := 0
	for quest: Dictionary in quests:
		if str(quest.get("state", "")) == "active":
			active_count += 1
	var title_text := "Quest Log (%d/%d)" % [active_count, LOG_CAP]  # T-621: log occupancy
	var summary: Array[String] = [title_text]
	_add_title(title_text)
	if quests.is_empty():
		var empty := Label.new()
		empty.text = "No quests."
		empty.add_theme_color_override("font_color", Color(0.53, 0.53, 0.53))
		_list.add_child(empty)
		summary.append("No quests.")
	for group: Dictionary in _GROUPS:
		var header_added := false
		for quest: Dictionary in quests:
			if str(quest.get("state", "")) != group["state"]:
				continue
			if not header_added:
				_add_header(str(group["header"]))
				summary.append(str(group["header"]))
				header_added = true
			summary.append_array(_add_card(quest, group))
	_summary = "\n".join(summary)
	# T-461: the objective tracker mirrors this same state — no second server message.
	objectives_changed.emit(active_tracker_model())


# T-058: targeted update — upsert (or remove, entry == null) ONE quest and re-render locally.
func apply_delta(quest_id: String, entry) -> void:
	var next: Array = []
	var replaced := false
	for quest: Dictionary in _quests:
		if str(quest.get("quest_id", "")) == quest_id:
			if entry is Dictionary:
				next.append(entry)
			replaced = true  # entry == null -> dropped (abandoned)
		else:
			next.append(quest)
	if not replaced and entry is Dictionary:
		next.append(entry)
	render(next)


# T-461: the view-model the always-on HUD tracker renders — every ACTIVE quest with only its
# INCOMPLETE objectives (a met objective drops off the tracker). The tracker itself caps how many
# quests it shows; this returns the full active set so the cap lives in one place (the view).
func active_tracker_model() -> Array:
	var out: Array = []
	for quest: Dictionary in _quests:
		if str(quest.get("state", "")) != "active":
			continue
		var incomplete: Array = []
		for obj: Dictionary in quest.get("objectives", []):
			var cur := int(obj.get("current", 0))
			var req := int(obj.get("required", 0))
			if req > 0 and cur >= req:
				continue  # objective met — it drops off the tracker
			incomplete.append({"desc": str(obj.get("desc", "")), "current": cur, "required": req})
		(
			out
			. append(
				{
					"title": str(quest.get("title", "")),
					"objectives": incomplete,
					"difficulty": str(quest.get("difficulty", "")),  # T-621: tracker paints the same band
					"elite": bool(quest.get("elite", false)),  # T-622: tracker paints the Elite badge
				}
			)
		)
	return out


func _add_title(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	lbl.add_theme_font_size_override("font_size", 18)
	_list.add_child(lbl)


# T-569 (portal #24): pure predicate — a quest already in the "complete" state must never render a
# Turn In action. quest_state_machine.gd (T-033) only ever moves a quest to "complete" through a
# SUCCESSFUL turn_in (evaluate_turn_in: active -> complete); "ready to turn in" is derived from
# objectives and is never itself a stored state. So every card under the "Completed" header is
# already turned in — re-pressing Turn In is a correct server no-op ("not_active"), but showing an
# actionable button on a quest that's already done reads as broken. Keyed on the quest's own state
# (not the render-order group) so it stays correct if a future state model adds more states.
static func should_show_turn_in(quest: Dictionary) -> bool:
	return str(quest.get("state", "")) != "complete"


func _add_header(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.55, 0.85, 0.99))  # 8be9fd cyan section head
	_list.add_child(lbl)


# One quest card: colored title + a right-aligned action button, then a progress row per objective.
func _add_card(quest: Dictionary, group: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_stylebox())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	card.add_child(box)
	# Title row: title (left, state-colored) + action button (right).
	var title_row := HBoxContainer.new()
	var title := Label.new()
	title.text = str(quest.get("title", ""))
	# T-621: an ACTIVE quest with a known difficulty band paints its title that colour (the pacing
	# UI); everything else keeps its group colour (completed = green, unknown = white).
	var title_hex := str(group["hex"])
	if group["state"] == "active" and _DIFFICULTY_HEX.has(str(quest.get("difficulty", ""))):
		title_hex = str(_DIFFICULTY_HEX[str(quest["difficulty"])])
	title.add_theme_color_override("font_color", Color.html("#" + title_hex))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	lines.append(str(quest.get("title", "")))
	# T-622: the group/elite badge (server flag recommended_players > 1) rides the log row too, so the
	# window, the tracker and the offer card all mark the same quest "Elite".
	if bool(quest.get("elite", false)):
		var badge := Label.new()
		badge.text = "⚔ Elite"
		badge.add_theme_color_override("font_color", Color(1.0, 0.62, 0.28))
		title_row.add_child(badge)
		lines.append("Elite")
	var qid := str(quest.get("quest_id", ""))
	var meta := ""
	if group["state"] == "complete" and should_show_turn_in(quest):
		meta = "turn_in|%s" % qid
		title_row.add_child(_action_button("Turn In", meta, Color(0.4, 1.0, 0.4)))
	elif group["state"] == "active":
		meta = "abandon|%s" % qid
		title_row.add_child(_action_button("Abandon", meta, Color(1.0, 0.53, 0.4)))
	box.add_child(title_row)
	# Objective progress rows.
	for obj: Dictionary in quest.get("objectives", []):
		var cur := int(obj.get("current", 0))
		var req := int(obj.get("required", 0))
		var met := req > 0 and cur >= req
		var row := HBoxContainer.new()
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = float(maxi(req, 1))
		bar.value = float(cur)
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(90.0, 12.0)
		if met:
			bar.add_theme_stylebox_override("fill", UiTheme.fill_stylebox(Color(0.4, 0.8, 0.35)))
		row.add_child(bar)
		var desc := Label.new()
		var mark := "✓ " if met else ""
		desc.text = "%s%s  %d/%d" % [mark, str(obj.get("desc", "")), cur, req]
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(desc)
		box.add_child(row)
		lines.append("%s%s: %d/%d" % [mark, str(obj.get("desc", "")), cur, req])
	_list.add_child(card)
	return lines


func _action_button(label: String, meta: String, tint: Color) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.add_theme_color_override("font_color", tint)
	btn.pressed.connect(func(): action_selected.emit(meta))
	_action_metas.append(meta)
	return btn


func _card_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.25)
	sb.border_color = Color(UiTheme.BRONZE.r, UiTheme.BRONZE.g, UiTheme.BRONZE.b, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	return sb


# ---- headless-test accessors ----


func get_quest_count() -> int:
	return _count


func get_text() -> String:
	return _summary


func get_action_metas() -> Array[String]:
	return _action_metas


func set_open(open: bool) -> void:
	visible = open


func toggle() -> void:
	visible = not visible
