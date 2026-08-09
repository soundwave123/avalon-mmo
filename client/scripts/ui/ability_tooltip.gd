class_name AbilityTooltip
# T-464: action-bar hover tooltip — read your ability. A small bordered panel that follows the mouse
# over an action-bar slot, showing the ability NAME, a one-line description, resource COST, and
# COOLDOWN. It REUSES the spellbook's builder (SpellbookPanel.format_tooltip) so the bar and the
# spellbook (B) speak one language, then appends the cooldown + keybind lines the spellbook drops.
# Mirrors item_tooltip.gd (top_level mouse-follow, MOUSE_FILTER_IGNORE so it never steals a click)
# and the T-396 HUD model (subtle surface, no heavy chrome).
#
# build_text()/locked_text() are pure String builders kept free of Node/viewport state so they unit
# -test without a live scene tree; _ready()/_process() do the live mouse-follow.

extends PanelContainer

const _PAD := 8
const _OFFSET := Vector2(18, 18)
const TICKS_PER_SEC := 20.0  # server tick rate (server_config.gd; agrees with the bar's GCD math)

var _label: RichTextLabel = null


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # a tooltip never eats a click on the slot beneath it
	top_level = true  # follow the mouse in viewport space, independent of the action bar's layout
	custom_minimum_size = Vector2(230, 0)
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
	_label.custom_minimum_size = Vector2(214, 0)
	add_child(_label)


func _process(_delta: float) -> void:
	if visible:
		_follow_mouse()


# Show the tooltip for a filled slot. `resource_kind` names the cost line's resource; `hotkey` is
# the slot's keybind pip string (shown so the player learns which key fires this ability).
func show_ability(ability: Dictionary, resource_kind: String, hotkey: String) -> void:
	_label.text = build_text(ability, resource_kind, hotkey)
	visible = true
	_follow_mouse()


# Show the tooltip for a locked/future slot — signals more abilities unlock as you level.
func show_locked(hotkey: String) -> void:
	_label.text = locked_text(hotkey)
	visible = true
	_follow_mouse()


func hide_tooltip() -> void:
	visible = false


func _follow_mouse() -> void:
	var vp_size := get_viewport_rect().size
	var pos := get_viewport().get_mouse_position() + _OFFSET
	pos.x = clamp(pos.x, 0.0, maxf(0.0, vp_size.x - size.x))
	pos.y = clamp(pos.y, 0.0, maxf(0.0, vp_size.y - size.y))
	global_position = pos


# Pure builder: ability dict -> tooltip BBCode. Body = the spellbook's rich block (name / cast+range
# / cost / magnitude / effect description); then the COOLDOWN line and a keybind hint the bar adds.
static func build_text(ability: Dictionary, resource_kind: String, hotkey: String) -> String:
	var lines: Array[String] = [SpellbookPanel.format_tooltip(ability, resource_kind)]
	var cd := cooldown_label(ability)
	if cd != "":
		lines.append(cd)
	if hotkey != "":
		lines.append(keybind_line(hotkey))
	return "\n".join(lines)


# Cooldown line from cooldown_ticks (display only; the server owns the authoritative cooldown).
# Empty when the ability has no cooldown beyond the shared global cooldown.
static func cooldown_label(ability: Dictionary) -> String:
	var ticks := int(ability.get("cooldown_ticks", 0))
	if ticks <= 0:
		return ""
	var dim := UiTheme.PARCHMENT_DIM.to_html(false)
	return "[color=#%s]%.1f sec cooldown[/color]" % [dim, float(ticks) / TICKS_PER_SEC]


static func keybind_line(hotkey: String) -> String:
	var gold := UiTheme.GOLD_BRIGHT.to_html(false)
	return "[color=#%s]Press [%s][/color]" % [gold, hotkey]


# Locked/future slot tooltip — the bar must not read as "this is all you get".
static func locked_text(hotkey: String) -> String:
	var gold := UiTheme.GOLD_BRIGHT.to_html(false)
	var dim := UiTheme.PARCHMENT_DIM.to_html(false)
	var lines: Array[String] = []
	lines.append("[b][color=#%s]Locked slot[/color][/b]" % gold)
	lines.append("[i][color=#%s]A new ability unlocks here as you level.[/color][/i]" % dim)
	if hotkey != "":
		lines.append("[color=#%s]Bound to [%s][/color]" % [gold, hotkey])
	return "\n".join(lines)
