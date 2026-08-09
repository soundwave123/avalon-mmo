class_name SpellbookPanel
extends Control

# T-422b: the spellbook — a modern-MMO ability reference. Lists every ability in the character's
# class kit (icon + name) and, on select, shows a WoW-style rich tooltip built from the ability
# metadata the server already ships in the `class_kit` payload: cast time (cast_ticks), range
# (range_units), resource cost (resource_cost/mana_cost + the class resource name), damage/heal
# range (base_damage|heal_base x variance_min..max, with the stat coefficient), and a one-line
# effect description derived from the effect verb.
#
# READ-ONLY: no intents, no new server surface. The client only RENDERS the server-authored display
# numbers — it never re-derives a gameplay value from them (the executor rolls the authoritative
# damage server-side). Toggled with B (chat-focus-gated like K/P/O/G/Y — no fire while typing).
#
# Window shape mirrors recipe_panel/pvp_panel's CURRENT idiom (a32d538 + T-400): a SolidWindow
# PanelContainer with a self-carried theme and EXPLICIT anchor assignment AFTER add_child (never
# set_anchors_preset — the preset recompute collapses containers on 4.7). An internal
# ScrollContainer wraps the list so a large kit can't overflow 720p.

const TICKS_PER_SEC := 20.0  # server tick rate (server_config.gd; action_bar's GCD math agrees)
const MELEE_YARDS := 5.0  # range_units at/below this reads as melee rather than a yard figure
const _ICON_DIR := "res://assets/icons/abilities/"  # T-422a icon art (game-icons.net, CC-BY 3.0)

var _kit: Array = []  # class-kit rows (server truth, from the class_kit message)
var _resource_kind: String = "none"  # "rage" | "mana" | "none" — the character's class resource
var _selected: int = -1

var _is_typing_fn: Callable = Callable()  # chat focus gate — B must not fire while typing
var _list: VBoxContainer = null
var _detail: RichTextLabel = null
var _rows: Array = []  # the clickable ability buttons, index-aligned with _kit


func _ready() -> void:
	visible = false  # toggled open with B
	# EXPLICIT anchors (never set_anchors_preset — the preset recompute collapses containers on 4.7).
	# Centered window, sized to sit inside 720p with margin.
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -300.0
	offset_right = 300.0
	offset_top = -220.0
	offset_bottom = 220.0
	# T-400: the shared theme's SolidWindow frame — self-carried (settings_panel idiom) so the
	# "SolidWindow" variation resolves without depending on an ancestor's theme.
	theme = UiTheme.build()
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	add_child(frame)
	# EXPLICIT anchors on the frame too, AFTER add_child (inventory_panel lesson).
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

	var header := Label.new()
	header.name = "Header"
	header.text = "Spellbook  (B)"
	header.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	col.add_child(header)

	# Two-pane body: a scrollable icon+name list on the left, the rich tooltip on the right.
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)

	var scroll := ScrollContainer.new()
	scroll.name = "ListScroll"
	scroll.custom_minimum_size = Vector2(220.0, 0.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	_list = VBoxContainer.new()
	_list.name = "AbilityList"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)  # T-422c: breathing room so names don't touch
	scroll.add_child(_list)

	_detail = RichTextLabel.new()
	_detail.name = "Detail"
	_detail.bbcode_enabled = true
	_detail.scroll_active = true
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_detail)

	_rebuild()


# main.gd wires the chat-typing gate once (the panel is read-only — no transport/reply_router).
func setup(is_typing_fn: Callable) -> void:
	_is_typing_fn = is_typing_fn


# Feed the class kit (the same Array the action bar receives on class_kit). Rebuilds the list.
func set_kit(kit: Array) -> void:
	# T-555: same distinct-icon resolution the action bar applies, so the spellbook's icon column
	# doesn't repeat the Heroic Strike / Sunder Armor glyph for Pummel / Concussive Blow.
	_kit = AbilityIcons.deduped(kit)
	_selected = 0 if not kit.is_empty() else -1
	_rebuild()


# The character's class resource kind ("rage" | "mana" | "none"), fed from the self broadcast entry
# so the cost line names the resource correctly (priest defs mix resource_cost/mana_cost fields).
func set_resource_kind(kind: String) -> void:
	if kind == _resource_kind:
		return
	_resource_kind = kind
	_render_detail()


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	if (event as InputEventKey).keycode != KEY_B:
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	if _is_typing_fn.is_valid() and bool(_is_typing_fn.call()):
		return  # chat holds the keyboard
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible


func select_ability(index: int) -> void:
	if index < 0 or index >= _kit.size():
		return
	_selected = index
	_render_detail()


# ---- rendering ---------------------------------------------------------------


func _rebuild() -> void:
	if _list == null:
		return
	for r in _rows:
		(r as Node).queue_free()
	_rows.clear()
	for i in range(_kit.size()):
		var ability: Dictionary = _kit[i]
		_rows.append(_build_row(i, ability))
	_render_detail()


func _build_row(index: int, ability: Dictionary) -> Button:
	var btn := Button.new()
	btn.name = "Row%d" % index
	btn.flat = true
	btn.focus_mode = Control.FOCUS_ALL  # keyboard-accessible selection
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# T-584: enforce minimum row height (icon 28px + padding) so clickable area matches visible row.
	# Without this, the button shrinks to label height (~8px) while the visible row is icon height.
	btn.custom_minimum_size = Vector2(0.0, 28.0)
	btn.pressed.connect(func(): select_ability(index))
	# T-422c: a spellbook row is a drag SOURCE — drag it onto an action-bar slot to place the ability
	# there. Click still selects (a click is press+release; a drag needs motion). No drop target here.
	var ab_id := int(ability.get("id", -1))
	btn.set_drag_forwarding(
		_get_row_drag.bind(ab_id, str(ability.get("icon", ""))), Callable(), Callable()
	)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(row)
	var icon_tex := _load_icon(str(ability.get("icon", "")))
	if icon_tex != null:
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.texture = icon_tex
		icon.custom_minimum_size = Vector2(28.0, 28.0)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon)
	var name_label := Label.new()
	name_label.name = "Name"
	name_label.text = str(ability.get("name", "?"))
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)
	_list.add_child(btn)
	return btn


# T-422c: drag SOURCE payload for a spellbook row — the action bar accepts `source: "book"` drops
# and places the ability into the target slot. A lifted, semi-transparent icon follows the cursor.
func _get_row_drag(_at_position: Vector2, ability_id: int, icon_slug: String) -> Variant:
	var tex := _load_icon(icon_slug)
	if tex != null:
		var preview := TextureRect.new()
		preview.texture = tex
		preview.custom_minimum_size = Vector2(40.0, 40.0)
		preview.size = Vector2(40.0, 40.0)
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		preview.position = Vector2(-20.0, -20.0)
		preview.modulate = Color(1, 1, 1, 0.7)
		var holder := Control.new()
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(preview)
		set_drag_preview(holder)
	return {"source": "book", "ability_id": ability_id}


func _render_detail() -> void:
	if _detail == null:
		return
	if _selected < 0 or _selected >= _kit.size():
		_detail.text = (
			"[color=#%s](Select an ability.)[/color]" % UiTheme.PARCHMENT_DIM.to_html(false)
		)
		return
	_detail.text = format_tooltip(_kit[_selected], _resource_kind)


func _load_icon(icon_slug: String) -> Texture2D:
	if icon_slug.is_empty():
		return null
	var path := _ICON_DIR + icon_slug + ".png"
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


# ---- pure tooltip formatting (unit-tested without instantiating the Control) ----


# The WoW-style rich tooltip for one ability: name header, then the stat lines (cast / range / cost
# / damage-or-heal), then the one-line effect description. `resource_kind` names the class resource.
static func format_tooltip(ability: Dictionary, resource_kind: String) -> String:
	var gold := UiTheme.GOLD_BRIGHT.to_html(false)
	var dim := UiTheme.PARCHMENT_DIM.to_html(false)
	var lines: Array[String] = []
	lines.append("[b][color=#%s]%s[/color][/b]" % [gold, str(ability.get("name", "?"))])
	lines.append("[color=#%s]%s     %s[/color]" % [dim, cast_label(ability), range_label(ability)])
	lines.append(cost_label(ability, resource_kind))
	var magnitude := magnitude_label(ability)
	if magnitude != "":
		lines.append(magnitude)
	lines.append("[i]%s[/i]" % effect_line(ability))
	return "\n".join(lines)


static func cast_label(ability: Dictionary) -> String:
	var ticks := int(ability.get("cast_ticks", 0))
	if ticks <= 0:
		return "Instant"
	return "%.1f sec cast" % (float(ticks) / TICKS_PER_SEC)


static func range_label(ability: Dictionary) -> String:
	var units := float(ability.get("range_units", 0.0))
	if units <= 0.0:
		return "Self"
	if units <= MELEE_YARDS:
		return "Melee range"
	return "%d yd range" % int(round(units))


# Cost = whichever of the two cost fields the def carries (priest defs mix them), named by the class
# resource. Zero on both → "No cost". Tinted to the resource colour when known.
static func cost_label(ability: Dictionary, resource_kind: String) -> String:
	var cost := int(ability.get("resource_cost", 0))
	if cost <= 0:
		cost = int(ability.get("mana_cost", 0))
	if cost <= 0:
		return "[color=#%s]No cost[/color]" % UiTheme.PARCHMENT_DIM.to_html(false)
	var res_name := _resource_name(resource_kind)
	var tint := _resource_color(resource_kind).to_html(false)
	return "[color=#%s]%d %s[/color]" % [tint, cost, res_name]


# Damage or heal range: base × variance_min..variance_max, with the stat coefficient noted (WoW's
# "(+X% of Intellect)"). DISPLAY ONLY — the server rolls the authoritative value.
static func magnitude_label(ability: Dictionary) -> String:
	var effect := str(ability.get("effect", ""))
	var dim := UiTheme.PARCHMENT_DIM.to_html(false)
	var base := 0
	var noun := ""
	if effect == "heal":
		base = int(ability.get("heal_base", 0))
		noun = "healing"
	elif effect == "damage":
		base = int(ability.get("base_damage", 0))
		noun = "damage"
	else:
		return ""
	if base <= 0:
		return ""
	var vmin := float(ability.get("variance_min", 1.0))
	var vmax := float(ability.get("variance_max", 1.0))
	var lo := int(round(float(base) * vmin))
	var hi := int(round(float(base) * vmax))
	var span := "%d–%d %s" % [lo, hi, noun] if lo != hi else "%d %s" % [hi, noun]
	var verb := "Restores" if effect == "heal" else "Deals"
	var coeff := coeff_label(ability.get("attacker_stat_coeffs", {}))
	if coeff != "":
		return "%s %s  [color=#%s](%s)[/color]" % [verb, span, dim, coeff]
	return "%s %s" % [verb, span]


# "+50% Intellect" from {"int": 0.5}; joins multiple coeffs. Empty when the ability has none.
static func coeff_label(coeffs: Dictionary) -> String:
	var parts: Array[String] = []
	for stat in coeffs:
		var pct := int(round(float(coeffs[stat]) * 100.0))
		parts.append("+%d%% %s" % [pct, _stat_name(str(stat))])
	return ", ".join(parts)


# One-line effect description derived from the effect verb (no per-ability authored text needed).
static func effect_line(ability: Dictionary) -> String:
	match str(ability.get("effect", "")):
		"damage":
			return "Strikes an enemy for weapon and spell power."
		"heal":
			return "Mends a friendly target's wounds."
		"threat":
			return "Taunts the target, forcing it to attack you."
		"control":
			return "Impairs the target's ability to act."
		"revive":
			return "Returns a fallen ally to life."
		_:
			return "A learned ability of your class."


static func _resource_name(kind: String) -> String:
	match kind:
		"rage":
			return "Rage"
		"mana":
			return "Mana"
		"energy", "focus":
			return "Energy"
		_:
			return "Resource"


static func _resource_color(kind: String) -> Color:
	match kind:
		"rage":
			return UiTheme.RAGE
		"mana":
			return UiTheme.MANA
		"energy", "focus":
			return UiTheme.ENERGY
		_:
			return UiTheme.PARCHMENT


static func _stat_name(abbrev: String) -> String:
	match abbrev:
		"str":
			return "Strength"
		"int":
			return "Intellect"
		"agi":
			return "Agility"
		"sta":
			return "Stamina"
		"spi":
			return "Spirit"
		_:
			return abbrev.capitalize()


# ---- headless-test accessors -------------------------------------------------


func ability_count() -> int:
	return _rows.size()


func selected_index() -> int:
	return _selected


func get_detail_text() -> String:
	return _detail.text if _detail != null else ""


func row_name(index: int) -> String:
	if index < 0 or index >= _rows.size():
		return ""
	var row := (_rows[index] as Node).get_child(0) as Node
	return (row.get_node("Name") as Label).text


func row_icon_texture(index: int) -> Texture2D:
	if index < 0 or index >= _rows.size():
		return null
	var row := (_rows[index] as Node).get_child(0) as Node
	if row.has_node("Icon"):
		return (row.get_node("Icon") as TextureRect).texture
	return null
