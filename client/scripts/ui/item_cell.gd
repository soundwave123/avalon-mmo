class_name ItemCell
# T-422d: one framed inventory/equipment cell — the shared building block of the modern bag GRID
# (inventory_panel) and the PAPERDOLL slot frames (character_sheet_panel). Renders an item's icon
# (when icon art exists) or a tasteful rarity-tinted placeholder with the item's initials, a stack
# count, and a rarity-colored border. Empty cells show a faint slot hint (e.g. "Head"). Emits hover
# (for the shared ItemTooltip) and click (the owning panel maps the click to an equip/drop/unequip
# intent meta) — the cell itself is intent-free so it can be reused anywhere.
#
# Item icon art ships as of T-422e: a curated CC-BY game-icons.net pack resolved by type via
# ItemIcons.slug_for (a plate helm -> a helm icon, an unmapped weapon -> a sword). Bespoke per-item
# art can still be dropped into res://assets/icons/items/<item_id>.png (or set an "icon" slug on the
# enriched slot) to override the shared pack; a cell with no resolvable icon falls back to initials.

extends Panel

signal hovered(entry: Dictionary)  # mouse entered an OCCUPIED cell -> tooltip
signal unhovered  # mouse left -> hide tooltip
signal activated(button_index: int)  # left/right click on an occupied cell -> owner maps to intent
signal dropped(data: Dictionary)  # T-640: a compatible drag payload was released on this cell

const _ICON_DIR := "res://assets/icons/items/"
const SIZE := 48.0

var _entry: Dictionary = {}
var _icon: TextureRect = null
var _glyph: Label = null
var _count: Label = null
var _hint: Label = null
# T-640: optional drag source / drop target (bag cell = source, paperdoll live slot = target). A
# cell never needs to be both in this codebase, so one `set_drag_forwarding` call per role is fine —
# see action_bar.gd/spellbook_panel.gd, which use the same Godot forwarding contract directly.
var _drag_payload: Dictionary = {}  # non-empty + occupied => liftable
var _drop_sources: Array = []  # accepted payload["source"] tags => this cell is a drop target


func _ready() -> void:
	_build()


# Build the child nodes lazily and ONCE. The owning panels (inventory_panel, character_sheet_panel)
# call configure() right after add_child while their own subtree may not be in the SceneTree yet, so
# _ready() hasn't fired and the node refs would still be null — configure() previously crashed with
# "Invalid assignment of property 'texture' on a base object of type 'Nil'" (regressed with T-422d).
# The _icon-null guard makes this safe from both _ready() and configure() without double-building.
func _build() -> void:
	if _icon != null:
		return
	custom_minimum_size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Icon fills the cell (explicit anchors — never set_anchors_preset, the 4.7 collapse trap).
	_icon = TextureRect.new()
	_icon.name = "Icon"
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill(_icon, 3.0)
	add_child(_icon)
	# Placeholder initials, centered, shown when no icon art resolves.
	_glyph = Label.new()
	_glyph.name = "Glyph"
	_glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill(_glyph, 0.0)
	add_child(_glyph)
	# Empty-slot hint (e.g. the equip-slot name), faint + centered.
	_hint = Label.new()
	_hint.name = "Hint"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.add_theme_color_override("font_color", Color(0.55, 0.51, 0.42, 0.8))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill(_hint, 0.0)
	add_child(_hint)
	# Stack count, bottom-right.
	_count = Label.new()
	_count.name = "Count"
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_count.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill(_count, 2.0)
	add_child(_count)
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(func(): unhovered.emit())


# Explicit full-rect anchors with an inset — assign after add_child would also work, but these nodes
# are added right after so setting here is safe (they are not containers that recompute offsets).
func _fill(c: Control, inset: float) -> void:
	c.anchor_left = 0.0
	c.anchor_top = 0.0
	c.anchor_right = 1.0
	c.anchor_bottom = 1.0
	c.offset_left = inset
	c.offset_top = inset
	c.offset_right = -inset
	c.offset_bottom = -inset


# entry: an enriched slot dict {item_id, name, count, rarity, ...} or {} for an empty cell.
# empty_hint: faint centered text shown only when the cell is empty (equip-slot name; "" for bags).
func configure(entry: Dictionary, empty_hint: String = "") -> void:
	_build()  # safe before _ready(): the panels configure a cell right after add_child (see _build)
	_entry = entry
	var occupied := not entry.is_empty() and str(entry.get("name", "")) != ""
	var rarity := str(entry.get("rarity", "common"))
	add_theme_stylebox_override("panel", _cell_stylebox(rarity, occupied))
	if not occupied:
		_icon.texture = null
		_icon.visible = false
		_glyph.visible = false
		_count.visible = false
		_hint.text = _empty_hint_label(empty_hint)
		_hint.visible = empty_hint != ""
		return
	_hint.visible = false
	var tex := _resolve_icon(entry)
	if tex != null:
		_icon.texture = tex
		_icon.visible = true
		_glyph.visible = false
	else:
		_icon.visible = false
		_glyph.text = _abbrev(str(entry.get("name", "")))
		_glyph.add_theme_color_override("font_color", Color.html("#" + Rarity.color_hex(rarity)))
		_glyph.visible = true
	var cnt := int(entry.get("count", 1))
	_count.text = str(cnt)
	_count.visible = cnt > 1


# T-640: makes an OCCUPIED cell liftable — `payload` rides as the drag data (e.g. bag-drag-to-equip
# uses {"source": "bag", "index": i}). Empty cells return null from the drag callback (nothing to
# lift). Mirrors the spellbook-row drag source (T-422c): a lifted, semi-transparent icon preview.
func set_drag_source(payload: Dictionary) -> void:
	_drag_payload = payload
	set_drag_forwarding(_get_cell_drag, Callable(), Callable())


# T-640: accepts a drop whose payload["source"] is one of `sources` (e.g. a paperdoll live slot
# accepts ["bag"]); emits `dropped(data)` so the owner can route it to the existing equip intent.
func set_drop_target(sources: Array) -> void:
	_drop_sources = sources
	set_drag_forwarding(Callable(), _can_drop_cell, _drop_cell)


func _get_cell_drag(_at_position: Vector2) -> Variant:
	if _drag_payload.is_empty() or _entry.is_empty():
		return null
	var tex := _resolve_icon(_entry)
	# set_drag_preview asserts a LIVE engine drag is in progress — true whenever Godot itself calls
	# this as the drag-forwarding callback, but a direct unit-test call (T-640: exercising the
	# payload logic without simulating a real mouse drag) has no such drag, so guard it.
	var vp := get_viewport()
	if tex != null and vp != null and vp.gui_is_dragging():
		set_drag_preview(_drag_preview(tex))
	return _drag_payload.duplicate()


func _can_drop_cell(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and str((data as Dictionary).get("source", "")) in _drop_sources


func _drop_cell(_at_position: Vector2, data: Variant) -> void:
	dropped.emit(data as Dictionary)


func _drag_preview(tex: Texture2D) -> Control:
	var preview := TextureRect.new()
	preview.texture = tex
	preview.custom_minimum_size = Vector2(SIZE, SIZE)
	preview.size = Vector2(SIZE, SIZE)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.position = Vector2(-SIZE / 2.0, -SIZE / 2.0)
	preview.modulate = Color(1, 1, 1, 0.7)
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(preview)
	return holder


func get_entry() -> Dictionary:
	return _entry


func _on_enter() -> void:
	if not _entry.is_empty() and str(_entry.get("name", "")) != "":
		hovered.emit(_entry)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if _entry.is_empty() or str(_entry.get("name", "")) == "":
			return
		activated.emit(event.button_index)


# Resolution order: an explicit server `icon` slug or a per-item-id art file wins first (bespoke art
# can be dropped in later without code changes); otherwise ItemIcons.slug_for maps the item's
# type/slot to a shared pack icon (T-422e) so every item lights up rather than showing initials.
func _resolve_icon(entry: Dictionary) -> Texture2D:
	for candidate: String in [str(entry.get("icon", "")), str(entry.get("item_id", ""))]:
		if candidate != "":
			var path := _ICON_DIR + candidate + ".png"
			if ResourceLoader.exists(path):
				return load(path) as Texture2D
	var slug := ItemIcons.slug_for(entry)
	if slug != "":
		var slug_path := _ICON_DIR + slug + ".png"
		if ResourceLoader.exists(slug_path):
			return load(slug_path) as Texture2D
	return null


# First letters of up to two words ("Iron Sword" -> "IS", "Helm" -> "HE"), the ability-bar idiom.
func _abbrev(item_name: String) -> String:
	var words := item_name.strip_edges().split(" ", false)
	if words.is_empty():
		return "?"
	if words.size() == 1:
		return words[0].substr(0, 2).to_upper()
	return (str(words[0]).substr(0, 1) + str(words[1]).substr(0, 1)).to_upper()


func _empty_hint_label(slot_name: String) -> String:
	match slot_name:
		"Shoulders":
			return "Shldr"
		"Weapon":
			return "Weap"
		"Offhand":
			return "Off"
		_:
			return slot_name


func _cell_stylebox(rarity: String, occupied: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.14, 0.12, 0.92) if occupied else Color(0.10, 0.09, 0.08, 0.75)
	# Occupied cells carry a rarity-colored rim (WoW read); empty cells a quiet bronze rim.
	if occupied:
		sb.border_color = Color.html("#" + Rarity.color_hex(rarity))
	else:
		sb.border_color = Color(UiTheme.BRONZE.r, UiTheme.BRONZE.g, UiTheme.BRONZE.b, 0.6)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(3)
	return sb
