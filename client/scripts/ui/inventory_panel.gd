class_name InventoryPanel
# T-039 / T-422d: Inventory UI — a modern bag GRID plus an Equipped row, built from real ItemCell
# frames (icon-or-placeholder, stack count, rarity-colored rim, hover tooltip). Renders the enriched
# inventory view-model: 16 bag slots + the server's EQUIP_SLOTS (head/chest/legs/shoulders/weapon/
# offhand, T-420). Left-click a bag cell to equip, right-click to drop; left-click an equipped cell
# to unequip — the same intent metas the old text links emitted, so PanelActions + main.gd are
# unchanged. Emits `equipment_changed` so the paperdoll (character_sheet_panel) mirrors what's worn.
#
# Programmatic Control (no .tscn). Added under the HUD by main.gd, fed by the `inventory` reply via
# render(slots). Headless-testable via get_text()/get_bag_used()/get_cells().
#
# View-model (per slot) — the contract the world's enrich_inventory produces:
#   { "slot_type": "bag"|"head"|..., "slot_index": int, "item_id", "name", "count", "rarity", ... }

extends Control

signal action_selected(meta: String)  # T-056: an equip / drop / unequip intent meta
signal item_hover_started(item: Dictionary)  # T-233: mouse entered an item cell -> tooltip
signal item_hover_ended  # T-233: mouse left it -> the tooltip hides
signal equipment_changed(equip: Dictionary)  # T-422d: slot_type -> entry, for the paperdoll

# T-420: mirrors server inventory_logic.EQUIP_SLOTS (shoulders = pauldrons).
const _EQUIP_SLOTS := ["head", "shoulders", "chest", "legs", "weapon", "offhand"]
const _BAG_SLOTS := 16
const _BAG_COLS := 4

var _bag_grid: GridContainer = null
var _equip_grid: GridContainer = null
var _bags_header: Label = null
var _bag_used: int = 0
var _summary: String = ""


func _ready() -> void:
	# EXPLICIT anchors (never set_anchors_preset — the 4.7 HUD-blank trap): a fixed panel on the RIGHT.
	anchor_left = 1.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = -376.0
	offset_right = -16.0
	offset_top = 56.0
	offset_bottom = -56.0
	visible = false  # toggled open with I
	theme = UiTheme.build()  # T-400: SolidWindow variation resolves off the shared theme
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	add_child(frame)
	# EXPLICIT anchors on the frame too, AFTER add_child (the preset call's offset recompute collapses
	# containers to 17x16 stubs — a32d538).
	frame.anchor_left = 0.0
	frame.anchor_top = 0.0
	frame.anchor_right = 1.0
	frame.anchor_bottom = 1.0
	frame.offset_left = 0.0
	frame.offset_top = 0.0
	frame.offset_right = 0.0
	frame.offset_bottom = 0.0
	# Internal scroll caps the window to 720p; a plain VBox holds the sections (NOT an RTL, which once
	# collapsed to zero size inside a ScrollContainer).
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(scroll)
	var box := VBoxContainer.new()
	box.name = "List"
	box.custom_minimum_size = Vector2(332.0, 0.0)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)
	_add_title(box, "Inventory")
	_add_header(box, "Equipped")
	_equip_grid = GridContainer.new()
	_equip_grid.name = "EquipGrid"
	_equip_grid.columns = _EQUIP_SLOTS.size()
	box.add_child(_equip_grid)
	_bags_header = _add_header(box, "Bags")
	_bag_grid = GridContainer.new()
	_bag_grid.name = "BagGrid"
	_bag_grid.columns = _BAG_COLS
	box.add_child(_bag_grid)
	render([])


# slots: Array of enriched slot entries (see header). Rebuilds the Equipped row + Bags grid.
func render(slots: Array) -> void:
	var bag: Dictionary = {}  # slot_index -> entry
	var equip: Dictionary = {}  # slot_type -> entry
	for slot: Dictionary in slots:
		var slot_type := str(slot.get("slot_type", ""))
		if slot_type == "bag":
			bag[int(slot.get("slot_index", -1))] = slot
		else:
			equip[slot_type] = slot
	_bag_used = bag.size()
	var summary: Array[String] = ["Inventory", "Equipped"]

	for child in _equip_grid.get_children():
		child.free()
	for slot_type: String in _EQUIP_SLOTS:
		var entry: Dictionary = equip.get(slot_type, {})
		var cell := _add_cell(_equip_grid, entry, slot_type.capitalize())
		cell.activated.connect(func(_b): action_selected.emit("unequip|%s" % slot_type))
		summary.append("%s: %s" % [slot_type.capitalize(), _slot_summary(entry)])

	_bags_header.text = "Bags (%d/%d)" % [_bag_used, _BAG_SLOTS]
	summary.append("Bags (%d/%d)" % [_bag_used, _BAG_SLOTS])
	for child in _bag_grid.get_children():
		child.free()
	for i in range(_BAG_SLOTS):
		var entry: Dictionary = bag.get(i, {})
		var cell := _add_cell(_bag_grid, entry, "")
		var idx := i
		cell.activated.connect(func(button: int): _on_bag_click(button, idx, entry))
		# T-640: drag a bag item onto a paperdoll live slot to equip it (the drop side emits the
		# SAME "equip|<idx>" meta the click path already does — no new intent, just a second gesture).
		cell.set_drag_source({"source": "bag", "index": idx})
		if not entry.is_empty():
			summary.append("[%d] %s" % [i, _slot_summary(entry)])
	_summary = "\n".join(summary)
	equipment_changed.emit(equip)


# Build a cell, add it to `grid` (this fires ItemCell._ready), then configure + wire hover.
func _add_cell(grid: GridContainer, entry: Dictionary, empty_hint: String) -> ItemCell:
	var cell := ItemCell.new()
	grid.add_child(cell)
	cell.configure(entry, empty_hint)
	cell.hovered.connect(func(item): item_hover_started.emit(item))
	cell.unhovered.connect(func(): item_hover_ended.emit())
	return cell


func _on_bag_click(button: int, index: int, entry: Dictionary) -> void:
	if button == MOUSE_BUTTON_RIGHT:
		var cnt := int(entry.get("count", 1))
		action_selected.emit("drop|bag|%d|%d" % [index, cnt])
	else:
		action_selected.emit("equip|%d" % index)


func _slot_summary(entry: Dictionary) -> String:
	if entry.is_empty() or str(entry.get("name", "")) == "":
		return "(empty)"
	var cnt := int(entry.get("count", 1))
	var s := str(entry.get("name", ""))
	return "%s x%d" % [s, cnt] if cnt > 1 else s


func _add_title(box: VBoxContainer, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	lbl.add_theme_font_size_override("font_size", 18)
	box.add_child(lbl)


func _add_header(box: VBoxContainer, text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.55, 0.85, 0.99))  # 8be9fd cyan section head
	box.add_child(lbl)
	return lbl


# ---- headless-test accessors ----


func get_bag_used() -> int:
	return _bag_used


func get_cells() -> Array:
	return _bag_grid.get_children() + _equip_grid.get_children()


func get_text() -> String:
	return _summary


func set_open(open: bool) -> void:
	visible = open


func toggle() -> void:
	visible = not visible
