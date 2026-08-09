class_name ObjectiveTracker
# T-461: the always-on, non-interactive quest objective tracker pinned to the RIGHT edge of the HUD
# (the WoW objective tracker idiom) so a brand-new player running the tutorial sees their current
# objectives without opening the Quest Log window (L). It is a pure VIEW: it renders the same active
# quest view-model the QuestLogPanel already holds (fed via the panel's `objectives_changed`
# signal), so there is no second server message and the two surfaces can never drift.
#
# T-396 idle-HUD treatment: outlined+shadowed text (shared UiTheme) over a SUBTLE gradient backdrop,
# NO opaque box and NO thick border. Every node is MOUSE_FILTER_IGNORE, so the tracker (and the
# empty space around it) always passes a world click through to the ground beneath it. It condenses
# to nothing (hidden) when there is no active quest, and caps the visible quest count so it never
# blankets the play field.

extends Control

const MAX_QUESTS := 5  # cap so the tracker never sprawls over the play field (T-461 item 4)
# T-621: difficulty band -> title colour, matching QuestLogPanel._DIFFICULTY_HEX so the tracker and
# the log window paint a quest the same colour. Empty/unknown band falls back to the gold default.
const _DIFFICULTY_HEX := {
	"red": "ff4040",
	"orange": "ff8040",
	"yellow": "ffd030",
	"green": "40c040",
	"grey": "9d9d9d",
}
const _WIDTH := 300.0
const _TOP := 110.0  # clears the compass strip / top-center cluster

var _backdrop: TextureRect = null
var _panel: PanelContainer = null
var _list: VBoxContainer = null
var _summary: String = ""  # headless-test mirror of the on-screen text
var _visible_quests: int = 0


func _ready() -> void:
	# EXPLICIT anchors (never set_anchors_preset on a container — the 4.7 HUD-collapse trap): pinned
	# to the top-RIGHT corner, a fixed-width column that grows downward with content.
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	offset_left = -(_WIDTH + 16.0)
	offset_right = -16.0
	offset_top = _TOP
	offset_bottom = _TOP
	# Non-interactive: the tracker itself never eats a world click (T-461 item 2).
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiTheme.build()  # outlined/shadowed Label legibility over the world, shared skin

	# T-396: a subtle gradient for legibility over bright terrain — NOT a filled/bordered box. It
	# fills the tracker rect (which hugs the content height), so the darkening tracks the text.
	_backdrop = UiTheme.gradient_backdrop(0.24, false)
	_backdrop.name = "TrackerGradient"
	add_child(_backdrop)

	_panel = PanelContainer.new()
	_panel.name = "TrackerPanel"
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_theme_stylebox_override("panel", UiTheme.no_box_stylebox(8.0))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_list = VBoxContainer.new()
	_list.name = "TrackerList"
	_list.add_theme_constant_override("separation", 6)
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_list)

	render([])


# model: Array of active quests, each { "title": String, "objectives": [ { desc, current, required }
# — the INCOMPLETE ones only ] }. Produced by QuestLogPanel.active_tracker_model(). Rebuilds the
# column, caps it to MAX_QUESTS, and condenses (hides) when there is nothing active.
func render(model: Array) -> void:
	for child in _list.get_children():
		child.queue_free()
	var shown: Array = model.slice(0, MAX_QUESTS)
	_visible_quests = shown.size()
	visible = _visible_quests > 0  # fade/condense to nothing with no active quest (T-461 item 2)
	var lines: Array[String] = []
	for quest: Dictionary in shown:
		_add_quest(quest, lines)
	_summary = "\n".join(lines)
	# Hug the content height so the gradient backdrop tracks the text, never a tall empty band.
	var content_h := _list.get_combined_minimum_size().y + 16.0
	offset_bottom = offset_top + content_h


func _add_quest(quest: Dictionary, lines: Array[String]) -> void:
	var title := Label.new()
	title.text = str(quest.get("title", ""))
	# T-621: paint the difficulty band (matches the Quest Log window); gold when unknown.
	var band := str(quest.get("difficulty", ""))
	if _DIFFICULTY_HEX.has(band):
		title.add_theme_color_override("font_color", Color.html("#" + str(_DIFFICULTY_HEX[band])))
	else:
		title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	title.add_theme_font_size_override("font_size", 16)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# T-622: prefix the always-on tracker title with an Elite marker for group quests (server flag),
	# so a player watching the HUD knows a tracked quest wants a party without opening the log.
	if bool(quest.get("elite", false)):
		title.text = "⚔ " + title.text
	_list.add_child(title)
	lines.append(str(quest.get("title", "")))
	if bool(quest.get("elite", false)):
		lines.append("Elite")
	var objectives: Array = quest.get("objectives", [])
	if objectives.is_empty():
		# Active with every objective met = ready to hand in. Guide the player to the turn-in.
		_add_objective_row("✓ Ready to turn in", lines)
		return
	for obj: Dictionary in objectives:
		var cur := int(obj.get("current", 0))
		var req := int(obj.get("required", 0))
		_add_objective_row("%s  %d/%d" % [str(obj.get("desc", "")), cur, req], lines)


func _add_objective_row(text: String, lines: Array[String]) -> void:
	var row := Label.new()
	row.text = text
	row.add_theme_color_override("font_color", UiTheme.PARCHMENT)
	row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.add_child(row)
	lines.append(text)


# ---- headless-test accessors ----


func get_text() -> String:
	return _summary


func get_visible_quest_count() -> int:
	return _visible_quests
