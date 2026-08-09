class_name ItemTooltip
# T-233: item tooltip — read your drop. A small bordered panel that follows the mouse while
# hovering an inventory item-name [url] region (inventory_panel's meta_hover_started/ended), showing
# the rarity-colored name (T-231 Rarity) + body lines for slot / stats / sell value. Hidden by
# default; main.gd wires inventory_panel.item_hover_started/ended to show_for()/hide_tooltip().
#
# build_lines() is a pure Dictionary -> Array[String] builder kept free of Node/viewport state so
# it's unit-testable without a live scene tree; _ready()/_process() do the live mouse-follow.

extends PanelContainer

const _PAD := 8
const _OFFSET := Vector2(18, 18)
# T-422e comparison colors (WoW read): upgrades green, downgrades red.
const _UP_HEX := "5fe36b"
const _DOWN_HEX := "ff5555"
const _MUTED_HEX := "9aa0a6"
# Friendly stat display names; unmapped keys capitalize (future primaries like "agility").
const _STAT_NAMES := {"attack": "Damage", "armor": "Armor"}
# Equip slots a bag item can be compared against (a permutation of inventory_logic.EQUIP_SLOTS).
const _EQUIP_SLOTS := ["head", "shoulders", "chest", "legs", "weapon", "offhand"]

# T-681: the character's server-reported level, fed from CharacterSheetPanel's player_stats
# handler. 0 = not yet known (pre-login), which renders the requirement in neutral text rather
# than a false red on every item.
static var _char_level: int = 0

var _label: RichTextLabel = null
var _equipped: Dictionary = {}  # slot_type -> worn entry (from InventoryPanel.equipment_changed)


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_level = true  # follow the mouse in viewport space, independent of our parent's layout
	custom_minimum_size = Vector2(220, 0)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.05, 0.08, 0.94)
	bg.border_color = Color(0.5, 0.5, 0.58, 1.0)
	bg.set_border_width_all(1)
	bg.set_content_margin_all(_PAD)
	add_theme_stylebox_override("panel", bg)
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.custom_minimum_size = Vector2(204, 0)
	add_child(_label)


func _process(_delta: float) -> void:
	if visible:
		_follow_mouse()


# T-422e: cache the currently-worn gear (slot_type -> entry) so a bag item's tooltip can show a
# +/- comparison against what's worn in its slot. Fed from InventoryPanel.equipment_changed.
func set_equipment(equip: Dictionary) -> void:
	_equipped = equip


# T-681: the level the required_level line is colored against. Static so build_lines() stays a
# pure Dictionary -> lines builder (unit-testable without a scene tree), matching this file's
# existing contract. The SERVER still owns the gate — this only decides what the tooltip says.
static func set_character_level(level: int) -> void:
	_char_level = maxi(0, level)


# Shows the tooltip built from an enriched inventory slot dict (name/rarity/slot/stats/value), plus
# a WoW-style +/- comparison vs the item worn in the same slot when the hovered item sits in a bag.
func show_for(item: Dictionary) -> void:
	var lines := build_lines(item)
	if _should_compare(item):
		# Empty target slot -> compare_lines shows the item's own stats as an all-positive gain.
		var cmp := compare_lines(item, _equipped.get(str(item.get("slot", "")), {}))
		if not cmp.is_empty():
			lines.append("")  # blank spacer before the comparison block
			lines.append_array(cmp)
	_label.text = "\n".join(lines)
	visible = true
	_follow_mouse()


# Only a BAG item bound for an equip slot gets a comparison. Hovering an already-worn cell (its
# slot_type IS its equip slot) isn't compared — no bogus "+N vs equipped" on gear you already wear.
func _should_compare(item: Dictionary) -> bool:
	return str(item.get("slot_type", "")) == "bag" and _EQUIP_SLOTS.has(str(item.get("slot", "")))


func hide_tooltip() -> void:
	visible = false


func _follow_mouse() -> void:
	var vp_size := get_viewport_rect().size
	var pos := get_viewport().get_mouse_position() + _OFFSET
	pos.x = clamp(pos.x, 0.0, maxf(0.0, vp_size.x - size.x))
	pos.y = clamp(pos.y, 0.0, maxf(0.0, vp_size.y - size.y))
	global_position = pos


# Pure builder: enriched item dict -> tooltip lines. Header = colored name (T-231); body = slot,
# stat lines (stats.attack -> "Damage", stats.armor -> "Armor"), then coin sell value.
static func build_lines(item: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	var name := str(item.get("name", ""))
	var rarity := str(item.get("rarity", "common"))
	lines.append(Rarity.colorize(name, rarity))
	var slot := str(item.get("slot", ""))
	if slot != "" and slot != "none":
		lines.append(slot.capitalize())
	# T-681: the gear ladder's level dimension. `item_level` is shown as the piece's tier;
	# `required_level` turns RED when this character cannot equip it — the same refusal the
	# server enforces (item_level_gate.gd), surfaced before the player clicks. 1/1 = ungated
	# and renders nothing, so starter gear and materials look exactly as they did before.
	var item_level := int(item.get("item_level", 1))
	if item_level > 1:
		lines.append("[color=#%s]Item Level %d[/color]" % [_MUTED_HEX, item_level])
	var required_level := int(item.get("required_level", 1))
	if required_level > 1:
		var unmet := _char_level > 0 and _char_level < required_level
		var text := "Requires Level %d" % required_level
		lines.append("[color=#%s]%s[/color]" % [_DOWN_HEX, text] if unmet else text)
	var stats: Dictionary = item.get("stats", {})
	if stats.has("attack"):
		lines.append("Damage: %d" % int(stats["attack"]))
	if stats.has("armor"):
		lines.append("Armor: %d" % int(stats["armor"]))
	var vendor_value := int(item.get("vendor_value", 0))
	if vendor_value > 0:
		lines.append("Sell: %dc" % vendor_value)
	return lines


# Pure: per-stat delta (hovered item - equipped item) over the union of both stat blocks. An empty
# `equipped` (nothing worn in the slot) yields the item's own stats as all-positive deltas; the same
# item vs itself yields all-zero. Keys with a 0 net delta stay present (compare_lines drops them).
static func stat_deltas(item: Dictionary, equipped: Dictionary) -> Dictionary:
	var item_stats: Dictionary = item.get("stats", {})
	var eq_stats: Dictionary = equipped.get("stats", {}) if not equipped.is_empty() else {}
	var keys: Dictionary = {}
	for k: String in item_stats.keys():
		keys[k] = true
	for k: String in eq_stats.keys():
		keys[k] = true
	var out: Dictionary = {}
	for k: String in keys.keys():
		out[k] = int(item_stats.get(k, 0)) - int(eq_stats.get(k, 0))
	return out


# Pure: BBCode comparison lines (green "+N Stat" upgrades / red "-N Stat" downgrades) for a hovered
# item vs the equipped item in the same slot. Returns [] on no net change (identical stats),
# so an equipped-vs-equipped or a sidegrade shows nothing. Stats are sorted for a stable render.
static func compare_lines(item: Dictionary, equipped: Dictionary) -> Array[String]:
	var deltas := stat_deltas(item, equipped)
	var keys := deltas.keys()
	keys.sort()
	var rows: Array[String] = []
	for k: String in keys:
		var d := int(deltas[k])
		if d == 0:
			continue
		var stat_name := str(_STAT_NAMES.get(k, str(k).capitalize()))
		var hex := _UP_HEX if d > 0 else _DOWN_HEX
		var sign := "+" if d > 0 else ""  # negatives already carry their "-"
		rows.append("[color=#%s]%s%d %s[/color]" % [hex, sign, d, stat_name])
	if rows.is_empty():
		return rows
	rows.insert(0, "[color=#%s]vs equipped[/color]" % _MUTED_HEX)
	return rows
