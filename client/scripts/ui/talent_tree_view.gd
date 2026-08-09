class_name TalentTreeView
# T-508: the node-graph for ONE talent tree — the "laying bricks" surface the tester asked for.
#
# Talents are laid out in TIER ROWS (tier 1 at the top). Within a tier they spread left-to-right.
# Prerequisite chains are drawn as connector lines from the prereq node down to its dependent, so
# the eye follows the build downward. A gated tier is darkened with a lock until enough points sit
# in the tree (the mirror math lives in TalentTheme — the server still validates every spend).
#
# Feedback beats: a node whose rank just rose flashes (fill tick), and a tier that just crossed its
# unlock threshold gets a short role-coloured glow ("a brick laid"). Clicking a SPENDABLE node emits
# spend_requested(id); the panel forwards it as the spend_talent intent.
#
# Programmatic Control, manual child positioning (not a Container) so connector geometry is exact.
# Everything the tests need is exposed via accessors; the drawing is pure of gameplay state.

extends Control

signal spend_requested(talent_id: String)

const CELL_W := 150.0
const CELL_H := 104.0
const NODE_W := 122.0
const NODE_H := 84.0
const MARGIN := 16.0

var _role := "dps"
var _accent := Color(0.84, 0.36, 0.18)
var _nodes: Array = []  # [{id, tier, col, center: Vector2, state, ranks, max, prereq, button}]
var _by_id := {}  # id -> node dict (connector + prereq lookup)
var _last_ranks := {}  # id -> ranks at previous render (rank-up detection)
var _last_tree_points := -1  # tree points at previous render (tier-unlock detection)
var _last_ranked_up := ""  # id of the node that just gained a rank (test/feedback)
var _glow_tiers := {}  # tier -> true for tiers that just unlocked (fades out via _glow_t)
var _glow_t := 0.0  # 0..1 glow strength, driven by a Tween
var _tree_points := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS  # nodes still receive clicks; gaps fall through


# Render one tree. `defs` is the subset of talent defs for THIS tree (already tier-sorted); `spent`
# is the full spent map; `points_left` the character's unspent budget; `trees_meta` the optional
# reply `trees` array (role source). Rebuilds the node graph and runs the feedback beats.
func render(
	tree: String, defs: Array, spent: Dictionary, points_left: int, trees_meta: Array = []
) -> void:
	_role = TalentTheme.role_for_tree(tree, trees_meta)
	_accent = TalentTheme.role_color(_role)
	_tree_points = TalentTheme.points_in_tree(spent, defs, tree)
	var defs_by_id := TalentTheme.defs_by_id(defs)

	_detect_beats(defs, spent)
	_rebuild(defs, spent, points_left, defs_by_id)
	_size_to_content(defs)
	queue_redraw()


# ---- feedback-beat detection (runs BEFORE the rebuild replaces last-state) ------------------


func _detect_beats(defs: Array, spent: Dictionary) -> void:
	_last_ranked_up = ""
	for tal: Dictionary in defs:
		var id := str(tal.get("id", ""))
		var now := int(spent.get(id, 0))
		if _last_ranks.has(id) and now > int(_last_ranks[id]):
			_last_ranked_up = id  # a point was just spent here -> fill tick
	# Tier-unlock glow: any tier that was locked at the old point total but is unlocked now.
	_glow_tiers.clear()
	if _last_tree_points >= 0:
		for tal: Dictionary in defs:
			var tier := int(tal.get("tier", 1))
			if (
				not TalentTheme.is_tier_unlocked(_last_tree_points, tier)
				and TalentTheme.is_tier_unlocked(_tree_points, tier)
			):
				_glow_tiers[tier] = true
	if not _glow_tiers.is_empty():
		_start_glow()


func _start_glow() -> void:
	_glow_t = 1.0
	var tween := create_tween()
	tween.tween_method(_set_glow, 1.0, 0.0, 1.1)


func _set_glow(v: float) -> void:
	_glow_t = v
	queue_redraw()


# ---- node build ------------------------------------------------------------------------------


func _rebuild(defs: Array, spent: Dictionary, points_left: int, defs_by_id: Dictionary) -> void:
	for n in _nodes:
		(n["button"] as Node).queue_free()
	_nodes.clear()
	_by_id.clear()
	var col_in_tier := {}  # tier -> next free column
	for tal: Dictionary in defs:
		var id := str(tal.get("id", ""))
		var tier := int(tal.get("tier", 1))
		var col := int(col_in_tier.get(tier, 0))
		col_in_tier[tier] = col + 1
		var state := TalentTheme.node_state(tal, spent, _tree_points, points_left, defs_by_id)
		var center := Vector2(
			MARGIN + col * CELL_W + NODE_W * 0.5, MARGIN + (tier - 1) * CELL_H + NODE_H * 0.5
		)
		var node := {
			"id": id,
			"tier": tier,
			"col": col,
			"center": center,
			"state": state,
			"ranks": int(spent.get(id, 0)),
			"max": int(tal.get("max_ranks", 1)),
			"prereq": str(tal.get("prereq", "")) if tal.get("prereq") != null else "",
			"just_ranked": id == _last_ranked_up,
		}
		node["button"] = _build_button(tal, node)
		_nodes.append(node)
		_by_id[id] = node
	# Remember state for the NEXT render's beat detection.
	_last_ranks = {}
	for tal: Dictionary in defs:
		_last_ranks[str(tal.get("id", ""))] = int(spent.get(str(tal.get("id", "")), 0))
	_last_tree_points = _tree_points


func _build_button(tal: Dictionary, node: Dictionary) -> Button:
	var btn := Button.new()
	btn.name = "Node_%s" % str(tal.get("id", ""))
	btn.flat = true
	btn.focus_mode = Control.FOCUS_ALL
	btn.position = node["center"] - Vector2(NODE_W * 0.5, NODE_H * 0.5)
	btn.size = Vector2(NODE_W, NODE_H)
	btn.custom_minimum_size = Vector2(NODE_W, NODE_H)
	btn.tooltip_text = "%s\n%s" % [str(tal.get("name", "")), str(tal.get("desc", ""))]
	btn.add_theme_stylebox_override("normal", _node_stylebox(node["state"]))
	btn.add_theme_stylebox_override("hover", _node_stylebox(node["state"], true))
	btn.add_theme_stylebox_override("pressed", _node_stylebox(node["state"], true))
	var spendable: bool = node["state"] == TalentTheme.SPENDABLE
	btn.disabled = not spendable
	if node["state"] == TalentTheme.LOCKED:
		btn.modulate = Color(0.5, 0.5, 0.55, 1.0)  # darkened gate
	if spendable:
		var id := str(tal.get("id", ""))
		btn.pressed.connect(func(): spend_requested.emit(id))

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 2)
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.add_child(vbox)

	var icon := _icon_node(tal)
	vbox.add_child(icon)

	var name_label := Label.new()
	name_label.name = "Name"
	name_label.text = str(tal.get("name", ""))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(name_label)

	var rank := Label.new()
	rank.name = "Rank"
	rank.text = "%d/%d" % [int(node["ranks"]), int(node["max"])]
	rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rank.add_theme_font_size_override("font_size", 11)
	rank.add_theme_color_override("font_color", _rank_color(node))
	rank.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(rank)

	add_child(btn)
	if node["just_ranked"]:
		_flash(btn)
	return btn


# Icon: the T-422a slug art if it ships, else a role-tinted initials placeholder (item_cell idiom).
func _icon_node(tal: Dictionary) -> Control:
	var slug := TalentTheme.slug_for(tal)
	var path := "res://assets/icons/talents/%s.png" % slug
	var holder := CenterContainer.new()
	holder.custom_minimum_size = Vector2(0, 34)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(path):
		var tex := TextureRect.new()
		tex.texture = load(path) as Texture2D
		tex.custom_minimum_size = Vector2(30, 30)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(tex)
	else:
		holder.add_child(_placeholder_icon(tal))
	return holder


func _placeholder_icon(tal: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(30, 30)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(_accent.r, _accent.g, _accent.b, 0.32)
	sb.border_color = _accent
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", sb)
	var glyph := Label.new()
	glyph.name = "Glyph"
	glyph.text = _initials(str(tal.get("name", "")))
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", 12)
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(glyph)
	return panel


func _initials(talent_name: String) -> String:
	var words := talent_name.split(" ", false)
	if words.is_empty():
		return "?"
	if words.size() == 1:
		return str(words[0]).substr(0, 2).to_upper()
	return (str(words[0]).substr(0, 1) + str(words[1]).substr(0, 1)).to_upper()


func _rank_color(node: Dictionary) -> Color:
	if int(node["ranks"]) >= int(node["max"]) and int(node["max"]) > 0:
		return Color(0.40, 1.0, 0.40)  # maxed -> green
	if int(node["ranks"]) > 0:
		return Color(0.93, 0.80, 0.42)  # partially ranked -> gold
	return Color(0.66, 0.60, 0.47)  # untouched -> dim parchment


func _node_stylebox(state: String, hot: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(4)
	sb.set_border_width_all(2)
	match state:
		TalentTheme.MAXED:
			sb.bg_color = Color(0.10, 0.20, 0.10, 0.85)
			sb.border_color = Color(0.40, 0.85, 0.40)
		TalentTheme.SPENDABLE:
			sb.bg_color = Color(0.14, 0.12, 0.10, 0.9)
			sb.border_color = _accent.lightened(0.15) if hot else _accent
		TalentTheme.AVAILABLE_NO_POINTS:
			sb.bg_color = Color(0.14, 0.12, 0.10, 0.85)
			sb.border_color = Color(_accent.r, _accent.g, _accent.b, 0.45)
		_:  # LOCKED
			sb.bg_color = Color(0.08, 0.08, 0.09, 0.9)
			sb.border_color = Color(0.30, 0.30, 0.32)
	return sb


func _flash(btn: Button) -> void:
	# Fill tick: pop bright, settle back — the satisfying "click" of laying a brick.
	btn.modulate = Color(1.6, 1.5, 1.2, 1.0)
	var tween := create_tween()
	tween.tween_property(btn, "modulate", Color(1, 1, 1, 1), 0.35)


func _size_to_content(defs: Array) -> void:
	var max_tier := 1
	var max_cols := 1
	var per_tier := {}
	for tal: Dictionary in defs:
		var tier := int(tal.get("tier", 1))
		max_tier = maxi(max_tier, tier)
		per_tier[tier] = int(per_tier.get(tier, 0)) + 1
		max_cols = maxi(max_cols, int(per_tier[tier]))
	custom_minimum_size = Vector2(MARGIN * 2 + max_cols * CELL_W, MARGIN * 2 + max_tier * CELL_H)


# ---- drawing: connector lines + tier bands + lock glyphs + unlock glow ------------------------


func _draw() -> void:
	# Tier bands behind the nodes (very subtle) + the unlock glow for a tier that just opened.
	var width := custom_minimum_size.x
	var tiers := {}
	for n in _nodes:
		tiers[int(n["tier"])] = true
	for tier in tiers:
		var y := MARGIN + (int(tier) - 1) * CELL_H
		if _glow_tiers.has(tier) and _glow_t > 0.0:
			var g := Color(_accent.r, _accent.g, _accent.b, 0.32 * _glow_t)
			draw_rect(Rect2(0, y - 4, width, NODE_H + 8), g, true)
	# Connector lines from each prereq to its dependent.
	for n in _nodes:
		var prereq := str(n["prereq"])
		if prereq == "" or not _by_id.has(prereq):
			continue
		var from: Vector2 = _by_id[prereq]["center"]
		var to: Vector2 = n["center"]
		var satisfied: bool = _by_id[prereq]["state"] == TalentTheme.MAXED
		var col := _accent if satisfied else Color(0.35, 0.35, 0.38, 0.8)
		draw_line(from + Vector2(0, NODE_H * 0.4), to - Vector2(0, NODE_H * 0.4), col, 3.0)
	# Lock glyph on gated nodes.
	for n in _nodes:
		if n["state"] == TalentTheme.LOCKED:
			var c: Vector2 = n["center"]
			_draw_lock(c - Vector2(0, NODE_H * 0.5 - 8))


func _draw_lock(at: Vector2) -> void:
	# A tiny padlock: shackle arc + body — reads as "gated" without an art asset.
	var body := Rect2(at.x - 5, at.y, 10, 8)
	draw_rect(body, Color(0.75, 0.72, 0.60, 0.9), true)
	draw_arc(at + Vector2(0, 0), 4.0, PI, TAU, 10, Color(0.75, 0.72, 0.60, 0.9), 1.5)


# ---- headless-test accessors -----------------------------------------------------------------


func node_count() -> int:
	return _nodes.size()


func state_of(talent_id: String) -> String:
	return str(_by_id.get(talent_id, {}).get("state", ""))


func connector_count() -> int:
	var n := 0
	for node in _nodes:
		if str(node["prereq"]) != "" and _by_id.has(str(node["prereq"])):
			n += 1
	return n


func last_ranked_up_id() -> String:
	return _last_ranked_up


func newly_unlocked_tiers() -> Array:
	return _glow_tiers.keys()


func tree_points() -> int:
	return _tree_points


func role() -> String:
	return _role
