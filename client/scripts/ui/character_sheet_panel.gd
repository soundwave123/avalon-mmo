class_name CharacterSheetPanel
# T-295 / T-422d / T-640: the WoW-style character window. A live 3D paperdoll (PaperdollPreview,
# T-224/T-420 gear rendered via the SAME EntityVisuals.apply_gear the world model uses) sits between
# two slot columns + a bottom row (PaperdollSlots — the server's real EQUIP_SLOTS are interactive;
# every other WoW slot is a dim complete-looking chrome frame). Below: sectioned stats — header
# (name/level/class), Attributes (primaries), Combat (derived pools), Durability.
#
# Fed by THREE server-authoritative streams the client already receives, no new intents:
#   - `player_stats` (update_stats) -> header + Attributes + Combat.
#   - the `inventory` reply's equip slots (update_equipment, forwarded by InventoryPanel via
#     equipment_changed — also fires after every equip/unequip round trip, T-570) -> slot frames.
#   - the positions broadcast's own-player row (update_preview, T-225 `gear`/`char_class`/
#     `username`) -> the live model, instantly on every tick (equip changes land within one tick).
#
# Click a worn slot to unequip, drag a bag item onto a live slot (or click it in the bag) to equip —
# both round-trip through the EXISTING PanelActions "equip|<idx>"/"unequip|<slot>" intents via
# `action_selected` (the same wiring quest_log_panel/inventory_panel/talent_panel already use).
# Programmatic Control. Toggled with C.

extends Control

signal item_hover_started(item: Dictionary)  # T-233: hover a worn/bag-drag slot -> tooltip
signal item_hover_ended
signal action_selected(meta: String)  # T-640: equip|<bag_index> / unequip|<slot_type>

# Display order + labels + the derived line each primary drives (legibility over raw stat names).
const _PRIMARIES := [
	["str", "Strength", "melee attack power"],
	["stamina", "Stamina", "health"],
	["dex", "Dexterity", "endurance / attack economy"],
	["int", "Intellect", "mana / spell power"],
	["spirit", "Spirit", "mana regeneration"],
]
# T-640 safe-zone (the T-608/T-634 lesson: nothing may sit on Vitals or the hotbar at 1280x720).
# Vitals + its autoattack pip end at y=116 (player_hud.gd offsets); the action bar's top edge is
# 720-52-88 = 580 (action_bar.gd offset_top) and its left edge reaches x=379 at MAX_SLOTS — so the
# old T-422 band (y 56..664) overlapped BOTH. The window now opens BELOW the vitals block and ends
# ABOVE the hotbar; the internal scroll absorbs the shorter viewport.
# T-608: this was the first panel to get it right; the constants now live in the shared
# HudSafeZone module (hud_safe_zone.gd) so quest_log_panel.gd / talent_panel.gd read the SAME
# numbers instead of each re-deriving (or mis-deriving) them.
const SAFE_TOP := HudSafeZone.PANEL_SAFE_TOP  # below the vitals block (bottom 116)
const SAFE_BOTTOM := HudSafeZone.PANEL_SAFE_BOTTOM  # bottom at 720-148 = 572, clear of hotbar (580)

var _rtl: RichTextLabel = null
var _preview: PaperdollPreview = null
var _slots: PaperdollSlots = null
var _prev_primaries: Dictionary = {}  # last-seen values, for the "(+N)" level-up feedback
var _last: Dictionary = {}  # last rendered player_stats payload (headless-test visibility)
var _last_equip: Dictionary = {}  # last rendered equip dict (durability-line worn count)
var _username: String = ""  # T-640: from the positions broadcast's own row, for the header
var _char_class: String = ""


# main.gd: build + wire the panel in one call (the QuestOfferPanel/WardrobePanel.mount idiom) —
# keeps main.gd (at its 1000-line cap) to a single call site instead of a multi-line wiring block.
static func mount(hud: Node, item_tooltip, inventory_panel: InventoryPanel) -> CharacterSheetPanel:
	var panel := CharacterSheetPanel.new()
	panel.name = "CharacterSheetPanel"
	hud.add_child(panel)
	inventory_panel.equipment_changed.connect(func(eq): panel.update_equipment(eq))
	panel.item_hover_started.connect(func(item): item_tooltip.show_for(item))
	panel.item_hover_ended.connect(func(): item_tooltip.hide_tooltip())
	return panel


func _ready() -> void:
	# EXPLICIT anchors (never set_anchors_preset — the 4.7 HUD-blank trap): fixed panel on the LEFT.
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 1.0
	offset_left = 16.0
	offset_right = 380.0
	offset_top = SAFE_TOP
	offset_bottom = SAFE_BOTTOM
	visible = false  # toggled with C
	theme = UiTheme.build()  # T-400: SolidWindow variation resolves off the shared theme
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	add_child(frame)
	# EXPLICIT anchors on the frame too, AFTER add_child (the preset call collapses containers).
	frame.anchor_left = 0.0
	frame.anchor_top = 0.0
	frame.anchor_right = 1.0
	frame.anchor_bottom = 1.0
	frame.offset_left = 0.0
	frame.offset_top = 0.0
	frame.offset_right = 0.0
	frame.offset_bottom = 0.0
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(scroll)
	var box := VBoxContainer.new()
	box.name = "List"
	box.custom_minimum_size = Vector2(332.0, 0.0)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	_build_paperdoll(box)
	_rtl = RichTextLabel.new()
	_rtl.name = "Stats"
	_rtl.bbcode_enabled = true
	_rtl.fit_content = true
	box.add_child(_rtl)


# The doll: left slot column | live model preview | right slot column, plus a bottom weapon row
# (WoW reference layout — see the T-640 ticket). PaperdollSlots owns the WoW slot set + live/chrome
# split; PaperdollPreview owns the SubViewport model (headless-guarded, degrades to a placeholder).
func _build_paperdoll(box: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.name = "Paperdoll"
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var left := VBoxContainer.new()
	left.name = "LeftSlots"
	left.add_theme_constant_override("separation", 6)
	row.add_child(left)
	_preview = PaperdollPreview.new()
	_preview.name = "Preview"
	_preview.custom_minimum_size = Vector2(120.0, 168.0)
	row.add_child(_preview)
	var right := VBoxContainer.new()
	right.name = "RightSlots"
	right.add_theme_constant_override("separation", 6)
	row.add_child(right)
	var bottom := HBoxContainer.new()
	bottom.name = "BottomSlots"
	bottom.add_theme_constant_override("separation", 8)
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(bottom)
	_slots = PaperdollSlots.new()
	_slots.build(left, right, bottom)
	_slots.action_selected.connect(func(meta): action_selected.emit(meta))
	_slots.item_hover_started.connect(func(item): item_hover_started.emit(item))
	_slots.item_hover_ended.connect(func(): item_hover_ended.emit())


# equip: slot_type -> enriched worn-item entry (from InventoryPanel.equipment_changed). Fires after
# every equip/unequip round trip (T-570), so the doll and the Durability line update the same tick.
func update_equipment(equip: Dictionary) -> void:
	_last_equip = equip
	if _slots != null:
		_slots.update_equipment(equip)


# T-640: the positions broadcast's own-player row (main.gd's `p`) — the SAME data local_player.gd
# feeds EntityVisuals.apply_gear with, so the doll can never show gear the world model doesn't.
func update_preview(p: Dictionary) -> void:
	_username = str(p.get("username", _username))
	_char_class = str(p.get("char_class", _char_class))
	if _preview != null:
		_preview.update_preview(p)


# data: the server's player_stats payload {level, primaries:{...}, derived:{...}}.
func update_stats(data: Dictionary) -> void:
	# T-681: this panel already owns the item tooltip, and this payload already carries the
	# server-reported level — so the tooltip's "Requires Level N" line is colored from here
	# rather than adding a hop to main.gd (which sits at its 1000-line cap). Set before the
	# partial-payload return: a level-only payload should still update the gate coloring.
	ItemTooltip.set_character_level(int(data.get("level", 0)))
	if not data.has("primaries") and not data.has("derived"):
		return  # older/partial payload — nothing to show
	_last = data
	var primaries: Dictionary = data.get("primaries", {})
	var derived: Dictionary = data.get("derived", {})

	var lines: Array = []
	lines.append(_header_line(int(data.get("level", 1))))
	lines.append("\n[b][color=8be9fd]Attributes[/color][/b]")
	for row: Array in _PRIMARIES:
		var key: String = row[0]
		var val: int = int(primaries.get(key, 0))
		var delta: int = val - int(_prev_primaries.get(key, val))
		var gain := " [color=66ff66](+%d)[/color]" % delta if delta > 0 else ""
		lines.append(
			(
				"  %s: [color=ffffff]%d[/color]%s [color=6a6a72]— %s[/color]"
				% [row[1], val, gain, row[2]]
			)
		)

	lines.append("\n[b][color=8be9fd]Combat[/color][/b]")
	lines.append(_derived_line("Max Health", derived, "max_hp"))
	lines.append(_derived_line("Max Mana", derived, "max_mana"))
	lines.append(_derived_line("Endurance", derived, "endurance"))
	lines.append(_derived_line("Spell Power", derived, "spell_power"))
	lines.append(_derived_line("Mana Regen", derived, "mana_regen"))

	lines.append("\n[b][color=8be9fd]Durability[/color][/b]")
	lines.append(_durability_line())
	_rtl.text = "\n".join(lines)

	# Snapshot AFTER rendering so the next payload's deltas are the level-up's gains.
	_prev_primaries = primaries.duplicate(true)


func _header_line(level: int) -> String:
	var name := _username if _username != "" else "Character"
	var cls := _char_class.capitalize() if _char_class != "" else "Adventurer"
	return "[b]%s[/b] — Level [color=ffd866]%d[/color] %s" % [name, level, cls]


func _derived_line(label: String, derived: Dictionary, key: String) -> String:
	return "  %s: [color=ffffff]%d[/color]" % [label, int(derived.get(key, 0))]


# #80 (portal finding): no persistent durability indicator exists anywhere. Real per-item numbers
# require a server-side thread-through (durability.gd's map never reaches enrich_inventory today) —
# out of scope for this client-only ticket. Honest interim: worn-slot count, clearly labeled as not
# yet numeric, so the section reads as a placeholder wired for the follow-up rather than fake data.
func _durability_line() -> String:
	var live: Array = _slots.live_slot_types() if _slots != null else []
	var worn := 0
	for slot_type in live:
		if not (_last_equip.get(slot_type, {}) as Dictionary).is_empty():
			worn += 1
	var note := "per-item durability isn't reported by the server yet (see #80)"
	return (
		"  [color=ffffff]%d/%d slots worn[/color] [color=6a6a72]— %s[/color]"
		% [worn, live.size(), note]
	)


func toggle() -> void:
	visible = not visible


# ---- headless-test accessors ----


func get_text() -> String:
	return _rtl.text if _rtl != null else ""


func get_last() -> Dictionary:
	return _last


func get_slot_cell(slot_type: String) -> ItemCell:
	return _slots.get_slot_cell(slot_type) if _slots != null else null


func get_chrome_cell(slot_type: String) -> ItemCell:
	return _slots.get_chrome_cell(slot_type) if _slots != null else null


func get_preview() -> PaperdollPreview:
	return _preview
