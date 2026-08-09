class_name PaperdollSlots
extends RefCounted

# T-640: the WoW-shaped slot columns flanking the character window's live model. Reference layout
# (see T-640 ticket): LEFT column Head/Neck/Shoulder/Back/Chest/Shirt/Tabard/Wrist, RIGHT column
# Hands/Waist/Legs/Feet/Finger x2/Trinket x2, BOTTOM row Weapon/Offhand/Ranged.
#
# Only the server's actual EQUIP_SLOTS are LIVE (verified against inventory_logic.gd/durability.gd:
# head/chest/legs/weapon/offhand/shoulders, T-420 pauldrons) — those get real, interactive ItemCells
# wired to the EXISTING equip intents (PanelActions "equip|<bag_index>" / "unequip|<slot_type>", the
# same metas InventoryPanel already emits — see T-640: click a worn slot to unequip, drag a bag item
# onto a live slot to equip). Every other WoW slot renders as a dim, non-interactive CHROME frame
# (action_bar.gd's `_build_locked_slot` idiom: modulate 0.45, no input) so the window reads as a
# complete paperdoll and a future slot drops into an already-laid-out frame with no layout work.
#
# A pure builder + signal bus (RefCounted, not a Control): the caller owns the actual VBox/HBox
# containers it lays cells into, so it composes into character_sheet_panel's existing layout.

signal action_selected(meta: String)  # unequip|<slot_type> or equip|<bag_index>
signal item_hover_started(item: Dictionary)
signal item_hover_ended

# [slot_type, label, live]. Labels match InventoryPanel's existing Equipped-row wording (T-422d)
# so the two panels never disagree on what a slot is called; ItemCell's built-in hint abbreviation
# (Shoulders->Shldr, Weapon->Weap, Offhand->Off) already fits every LIVE label used here.
const _LEFT := [
	["head", "Head", true],
	["neck", "Neck", false],
	["shoulders", "Shoulders", true],
	["back", "Back", false],
	["chest", "Chest", true],
	["shirt", "Shirt", false],
	["tabard", "Tabard", false],
	["wrist", "Wrist", false],
]
const _RIGHT := [
	["hands", "Hands", false],
	["waist", "Waist", false],
	["legs", "Legs", true],
	["feet", "Feet", false],
	["finger1", "Finger", false],
	["finger2", "Finger", false],
	["trinket1", "Trinket", false],
	["trinket2", "Trinket", false],
]
const _BOTTOM := [
	["weapon", "Weapon", true],
	["offhand", "Offhand", true],
	["ranged", "Ranged", false],
]
const _CHROME_MODULATE := Color(1.0, 1.0, 1.0, 0.45)  # action_bar._build_locked_slot idiom

var _live_cells: Dictionary = {}  # slot_type -> ItemCell (interactive)
var _live_labels: Dictionary = {}  # slot_type -> label (configure() needs it re-passed each update)
var _chrome_cells: Dictionary = {}  # slot_type -> ItemCell (dim, no input)


# left/right/bottom: containers the caller already placed around the live-model preview.
func build(left: Container, right: Container, bottom: Container) -> void:
	for row: Array in _LEFT:
		_add_slot(left, row[0], row[1], row[2])
	for row: Array in _RIGHT:
		_add_slot(right, row[0], row[1], row[2])
	for row: Array in _BOTTOM:
		_add_slot(bottom, row[0], row[1], row[2])


func _add_slot(col: Container, slot_type: String, label: String, live: bool) -> void:
	var cell := ItemCell.new()
	col.add_child(cell)  # fires ItemCell._ready
	cell.configure({}, label)
	if not live:
		cell.modulate = _CHROME_MODULATE
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE  # chrome takes no input, ever
		_chrome_cells[slot_type] = cell
		return
	cell.hovered.connect(func(item): item_hover_started.emit(item))
	cell.unhovered.connect(func(): item_hover_ended.emit())
	cell.activated.connect(func(_button): action_selected.emit("unequip|%s" % slot_type))
	cell.set_drop_target(["bag"])  # accepts a drag lifted off an InventoryPanel bag cell (T-640)
	cell.dropped.connect(
		func(data: Dictionary): action_selected.emit("equip|%d" % int(data.get("index", -1)))
	)
	_live_cells[slot_type] = cell
	_live_labels[slot_type] = label


# equip: slot_type -> enriched worn-item entry (InventoryPanel.equipment_changed). Frames persist —
# only their contents change, so the empty-slot label must be re-passed every call (configure()
# doesn't remember it).
func update_equipment(equip: Dictionary) -> void:
	for slot_type: String in _live_cells:
		var cell: ItemCell = _live_cells[slot_type]
		cell.configure(equip.get(slot_type, {}), str(_live_labels.get(slot_type, "")))


func get_slot_cell(slot_type: String) -> ItemCell:
	return _live_cells.get(slot_type, null)


func get_chrome_cell(slot_type: String) -> ItemCell:
	return _chrome_cells.get(slot_type, null)


func live_slot_types() -> Array:
	return _live_cells.keys()


func chrome_slot_types() -> Array:
	return _chrome_cells.keys()
