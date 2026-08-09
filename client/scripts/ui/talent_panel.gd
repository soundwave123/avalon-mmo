class_name TalentPanel
# T-065 / T-508: the talent tree UI. T-508 overhauls the original flat BBCode list (playtest
# feedback #6 — "boring as reading the dictionary") into a real tree: one role-themed TAB per tree,
# a node-graph per tab with prerequisite connectors and gated tiers, per-talent icons, rank-up
# feedback, a prominent points-remaining readout, and a respec button.
#
# Reply contract (world _request_talents) unchanged:
#   { talents: {talent_id: ranks}, points_available, points_spent,
#     defs: [ {id, name, tree, tier, max_ranks, prereq, desc, ...} ], (optional) trees:[{id,role}] }
#
# Clicking a spendable node emits action_selected("spend_talent|<id>"); the respec confirm emits
# action_selected("reroll_talents"). The SERVER validates every spend/reroll — the client only
# predicts display state (TalentTheme mirrors the gate math). SolidWindow chrome kept (T-396/T-400).

extends Control

signal action_selected(meta: String)

var _points_label: Label = null
var _tab_bar: HBoxContainer = null
var _scroll: ScrollContainer = null
var _confirm: ConfirmationDialog = null
var _views := {}  # tree id -> TalentTreeView
var _tab_buttons := {}  # tree id -> Button
var _trees: Array = []  # ordered tree ids
var _active_tree := ""
var _talent_count := 0
var _points_left := 0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	offset_left = -560.0
	offset_right = -16.0
	# T-608: was offset_bottom=-56.0 — at this panel's extra width (720..1264 at MAX_SLOTS' hotbar
	# reach of x=379..901) the panel's left edge crosses INTO the hotbar's x-range, so horizontal
	# clearance can't be relied on the way the narrower siblings (recipe/pvp) get it for free.
	# Fixing the VERTICAL clearance instead (shared HudSafeZone constants, hud_safe_zone.gd) makes
	# the panel provably clear of the hotbar regardless of its width or the hotbar's slot count.
	offset_top = HudSafeZone.PANEL_SAFE_TOP
	offset_bottom = HudSafeZone.PANEL_SAFE_BOTTOM
	visible = false  # toggled with N / opened by a class trainer
	# T-400: the shared theme's SolidWindow frame (settings_panel idiom) so every deliberate window
	# matches. EXPLICIT anchors, assigned AFTER add_child — never set_anchors_preset (the 4.7 trap
	# whose offset recompute collapses containers).
	theme = UiTheme.build()
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	add_child(frame)
	frame.anchor_left = 0.0
	frame.anchor_top = 0.0
	frame.anchor_right = 1.0
	frame.anchor_bottom = 1.0
	frame.offset_left = 0.0
	frame.offset_top = 0.0
	frame.offset_right = 0.0
	frame.offset_bottom = 0.0

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	frame.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)

	col.add_child(_build_header())

	_tab_bar = HBoxContainer.new()
	_tab_bar.name = "TabBar"
	_tab_bar.add_theme_constant_override("separation", 6)
	col.add_child(_tab_bar)

	_scroll = ScrollContainer.new()
	_scroll.name = "TreeScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_scroll)

	_confirm = ConfirmationDialog.new()
	_confirm.name = "RespecConfirm"
	_confirm.title = "Respec Talents"
	_confirm.dialog_text = "Reset ALL talents? Every spent point is refunded."
	_confirm.confirmed.connect(_on_respec_confirmed)
	add_child(_confirm)


func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 10)

	var title := Label.new()
	title.text = "Talents"
	title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	title.add_theme_font_size_override("font_size", 18)
	header.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_points_label = Label.new()
	_points_label.name = "PointsLeft"
	_points_label.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	_points_label.add_theme_font_size_override("font_size", 18)
	_points_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_points_label)

	var respec := Button.new()
	respec.name = "RespecButton"
	respec.text = "Respec"
	respec.tooltip_text = "Refund every spent talent point (server-validated)."
	respec.pressed.connect(func(): _confirm.popup_centered())
	header.add_child(respec)
	return header


func toggle() -> void:
	visible = not visible


# Render the server talents reply into the tabbed tree.
func render(state: Dictionary) -> void:
	var spent: Dictionary = state.get("talents", {})
	var defs: Array = state.get("defs", [])
	var trees_meta: Array = state.get("trees", [])
	var available: int = int(state.get("points_available", 0))
	var used: int = int(state.get("points_spent", 0))
	_points_left = available - used
	_talent_count = defs.size()
	_points_label.text = "%d point%s to spend" % [_points_left, "" if _points_left == 1 else "s"]
	_points_label.add_theme_color_override(
		"font_color", UiTheme.GOLD_BRIGHT if _points_left > 0 else UiTheme.PARCHMENT_DIM
	)

	var trees := TalentTheme.tree_ids(defs)
	_rebuild_tabs(trees, defs, spent, trees_meta)
	_rebuild_views(trees, defs, spent, trees_meta)
	if _active_tree == "" or not trees.has(_active_tree):
		_active_tree = trees[0] if not trees.is_empty() else ""
	_trees = trees
	_show_active()


func _rebuild_tabs(trees: Array, defs: Array, spent: Dictionary, trees_meta: Array) -> void:
	for c in _tab_bar.get_children():
		(c as Node).queue_free()
	_tab_buttons.clear()
	for tree: String in trees:
		var role := TalentTheme.role_for_tree(tree, trees_meta)
		var pts := TalentTheme.points_in_tree(spent, defs, tree)
		var btn := Button.new()
		btn.name = "Tab_%s" % tree
		btn.text = "%s  %d" % [tree.capitalize(), pts]
		btn.tooltip_text = "%s tree (%s)" % [tree.capitalize(), role]
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(func(): select_tree(tree))
		_tab_buttons[tree] = btn
		_tab_bar.add_child(btn)


func _rebuild_views(trees: Array, defs: Array, spent: Dictionary, trees_meta: Array) -> void:
	for tree: String in trees:
		var subset := defs.filter(func(t): return str((t as Dictionary).get("tree", "")) == tree)
		var view: TalentTreeView = _views.get(tree)
		if view == null:
			view = TalentTreeView.new()
			view.name = "Tree_%s" % tree
			view.spend_requested.connect(_on_spend_requested)
			_views[tree] = view
			_scroll.add_child(view)
		view.render(tree, subset, spent, _points_left, trees_meta)
	# Drop views for trees that no longer exist (e.g. a class swap).
	for tree in _views.keys():
		if not trees.has(tree):
			(_views[tree] as Node).queue_free()
			_views.erase(tree)


func select_tree(tree: String) -> void:
	if not _views.has(tree):
		return
	_active_tree = tree
	_show_active()


func _show_active() -> void:
	for tree in _views:
		(_views[tree] as CanvasItem).visible = tree == _active_tree
	for tree in _tab_buttons:
		var role := TalentTheme.role_for_tree(tree)
		var btn := _tab_buttons[tree] as Button
		var is_active: bool = tree == _active_tree
		btn.add_theme_stylebox_override("normal", _tab_stylebox(role, is_active))
		btn.add_theme_stylebox_override("hover", _tab_stylebox(role, is_active))
		btn.add_theme_stylebox_override("pressed", _tab_stylebox(role, true))
		btn.add_theme_color_override(
			"font_color", UiTheme.PARCHMENT if is_active else UiTheme.PARCHMENT_DIM
		)


# A role-tinted tab: the ACTIVE tab is a loud role-coloured band; inactive tabs recede.
func _tab_stylebox(role: String, active: bool) -> StyleBoxFlat:
	var accent := TalentTheme.role_color(role)
	var sb := StyleBoxFlat.new()
	sb.bg_color = (
		Color(accent.r, accent.g, accent.b, 0.40)
		if active
		else Color(accent.r, accent.g, accent.b, 0.14)
	)
	sb.border_color = accent if active else Color(accent.r, accent.g, accent.b, 0.5)
	sb.set_border_width_all(1)
	sb.border_width_bottom = 3 if active else 1  # the role-coloured "which tab" underline
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _on_spend_requested(talent_id: String) -> void:
	action_selected.emit("spend_talent|%s" % talent_id)


func _on_respec_confirmed() -> void:
	action_selected.emit("reroll_talents")


# ---- headless-test accessors -----------------------------------------------------------------


func get_talent_count() -> int:
	return _talent_count


func get_points_left() -> int:
	return _points_left


func tab_count() -> int:
	return _tab_buttons.size()


func active_tree() -> String:
	return _active_tree


func tree_view(tree: String) -> TalentTreeView:
	return _views.get(tree)


func points_text() -> String:
	return _points_label.text if _points_label != null else ""


# Test hook: exercise the respec confirm path without popping the modal dialog.
func confirm_respec_for_test() -> void:
	_on_respec_confirmed()
