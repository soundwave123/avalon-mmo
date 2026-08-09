class_name PartyFrames
# T-285 (M8): the healer/tank readability surface — stacked left-side frames for your party
# (WoW party of 2-5, not raid). One row per member: class-colored name, health bar, resource
# bar, a leader pip, dimmed when out of range. Click a row to target that member (feeds T-283).
#
# set_party(rows) reconciles a small pool of row Controls (show N, hide the rest) so it does
# not churn nodes at the 1 Hz broadcast rate. Rows carry their own state, so the roster logic
# unit-tests without a live camera/tree; accessors expose per-row truth for assertions.

extends Control

signal member_clicked(peer_id: int)

const _ROW_W := 190.0
const _ROW_H := 42.0
const _GAP := 6.0
const _COL_GAP := 10.0  # T-472: gap between raid subgroup columns
const _BAR_W := 174.0
const _DIM := Color(1.0, 1.0, 1.0, 0.4)
const _LIT := Color(1.0, 1.0, 1.0, 1.0)

# T-334: trinity role legibility — a forming group must SEE whether it has a tank/healer.
# Client mirror of the server map in lfg_logic.gd (display-only; the LFG board's authoritative
# role is derived server-side from the session class).
const CLASS_ROLES := {"warrior": "tank", "priest": "heal", "mage": "dps"}
const ROLE_COLORS := {
	"tank": Color(0.35, 0.55, 0.92),  # shield blue
	"heal": Color(0.35, 0.85, 0.45),  # mend green
	"dps": Color(0.92, 0.38, 0.30),  # blade red
}
const READY_COLOR := Color(0.30, 0.95, 0.35)  # T-334: at-the-crypt-stair ready marker

var _rows: Array = []  # pool of {root, name, hp_fill, res_fill, pip, role, ready, peer_ref}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(12.0, 120.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hide()


# rows: Array of {peer_id, name, hp, max_hp, resource, max_resource, char_class, leader,
# in_range, ready (T-334: standing at the crypt stair), subgroup (T-472: raid column, default 0)}.
# Fewer than 2 members = not a party -> hidden (WoW: a party of one isn't shown).
# T-472: a raid lays out as one column per subgroup (5+5); a plain party (all subgroup 0)
# renders exactly as before in a single column.
func set_party(rows: Array) -> void:
	if rows.size() < 2:
		for r: Dictionary in _rows:
			r["root"].hide()
		hide()
		return
	while _rows.size() < rows.size():
		_rows.append(_make_row(_rows.size()))
	var slot_in_col := {}  # subgroup -> next row slot in that column
	for i in _rows.size():
		if i < rows.size():
			_bind_row(_rows[i], rows[i])
			var col := int(rows[i].get("subgroup", 0))
			var slot := int(slot_in_col.get(col, 0))
			slot_in_col[col] = slot + 1
			(_rows[i]["root"] as Control).position = Vector2(
				col * (_ROW_W + _COL_GAP), slot * (_ROW_H + _GAP)
			)
			_rows[i]["root"].show()
		else:
			_rows[i]["root"].hide()
	show()


func _make_row(index: int) -> Dictionary:
	var root := Control.new()
	root.position = Vector2(0.0, index * (_ROW_H + _GAP))
	root.custom_minimum_size = Vector2(_ROW_W, _ROW_H)
	root.size = Vector2(_ROW_W, _ROW_H)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.08, 0.7)
	bg.size = Vector2(_ROW_W, _ROW_H)
	root.add_child(bg)
	var name_label := Label.new()
	name_label.position = Vector2(6.0, 1.0)
	root.add_child(name_label)
	var hp_bg := ColorRect.new()
	hp_bg.color = Color(0.1, 0.1, 0.1, 1.0)
	hp_bg.position = Vector2(8.0, 20.0)
	hp_bg.size = Vector2(_BAR_W, 10.0)
	root.add_child(hp_bg)
	var hp_fill := ColorRect.new()
	hp_fill.color = Color(0.2, 0.8, 0.2)
	hp_fill.position = Vector2(8.0, 20.0)
	hp_fill.size = Vector2(_BAR_W, 10.0)
	root.add_child(hp_fill)
	var res_fill := ColorRect.new()
	res_fill.color = Color(0.25, 0.45, 0.9)
	res_fill.position = Vector2(8.0, 31.0)
	res_fill.size = Vector2(_BAR_W, 6.0)
	root.add_child(res_fill)
	var pip := ColorRect.new()  # leader marker
	pip.color = Color(1.0, 0.85, 0.2)
	pip.position = Vector2(_ROW_W - 12.0, 3.0)
	pip.size = Vector2(8.0, 8.0)
	pip.visible = false
	root.add_child(pip)
	var role := ColorRect.new()  # T-334: trinity role icon (color speaks: blue/green/red)
	role.position = Vector2(_ROW_W - 26.0, 3.0)
	role.size = Vector2(8.0, 8.0)
	root.add_child(role)
	var ready := ColorRect.new()  # T-334: lights when the member stands at the crypt stair
	ready.color = READY_COLOR
	ready.position = Vector2(_ROW_W - 40.0, 3.0)
	ready.size = Vector2(8.0, 8.0)
	ready.visible = false
	root.add_child(ready)
	var peer_ref := {"id": -1}
	root.gui_input.connect(func(ev: InputEvent): _on_row_input(ev, peer_ref))
	add_child(root)
	return {
		"root": root,
		"name": name_label,
		"hp_fill": hp_fill,
		"res_fill": res_fill,
		"pip": pip,
		"role": role,
		"ready": ready,
		"peer_ref": peer_ref,
	}


func _bind_row(row: Dictionary, data: Dictionary) -> void:
	var label: Label = row["name"]
	label.text = str(data.get("name", ""))
	label.add_theme_color_override("font_color", _class_color(str(data.get("char_class", ""))))
	(row["hp_fill"] as ColorRect).size = Vector2(
		_BAR_W * _ratio(int(data.get("hp", 0)), int(data.get("max_hp", 0))), 10.0
	)
	(row["res_fill"] as ColorRect).size = Vector2(
		_BAR_W * _ratio(int(data.get("resource", 0)), int(data.get("max_resource", 0))), 6.0
	)
	(row["pip"] as ColorRect).visible = bool(data.get("leader", false))
	(row["role"] as ColorRect).color = _role_color(str(data.get("char_class", "")))
	(row["ready"] as ColorRect).visible = bool(data.get("ready", false))
	(row["root"] as Control).modulate = _LIT if bool(data.get("in_range", true)) else _DIM
	row["peer_ref"]["id"] = int(data.get("peer_id", -1))


func _ratio(cur: int, maximum: int) -> float:
	return clampf(float(cur) / float(maximum), 0.0, 1.0) if maximum > 0 else 0.0


func _class_color(char_class: String) -> Color:
	return EntityVisuals.CLASS_COLORS.get(char_class, Color(0.85, 0.85, 0.85))


# T-334: class -> trinity role -> icon color (unknown class reads dps, the server's floor too).
func _role_color(char_class: String) -> Color:
	return ROLE_COLORS[str(CLASS_ROLES.get(char_class, "dps"))]


func _on_row_input(ev: InputEvent, peer_ref: Dictionary) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var pid := int(peer_ref["id"])
		if pid != -1:
			member_clicked.emit(pid)


# ---- headless-test accessors ----


func visible_row_count() -> int:
	var n := 0
	for r: Dictionary in _rows:
		if (r["root"] as Control).visible:
			n += 1
	return n


func row_name(i: int) -> String:
	return (_rows[i]["name"] as Label).text


func row_hp_ratio(i: int) -> float:
	return (_rows[i]["hp_fill"] as ColorRect).size.x / _BAR_W


func row_is_leader(i: int) -> bool:
	return (_rows[i]["pip"] as ColorRect).visible


func row_is_dimmed(i: int) -> bool:
	return (_rows[i]["root"] as Control).modulate.a < 1.0


# T-334: the row's rendered role, recovered from the icon color (what the player actually sees).
func row_role(i: int) -> String:
	var c: Color = (_rows[i]["role"] as ColorRect).color
	for role: String in ROLE_COLORS:
		if ROLE_COLORS[role] == c:
			return role
	return ""


func row_is_ready(i: int) -> bool:
	return (_rows[i]["ready"] as ColorRect).visible


# T-472: the row's rendered raid column, recovered from its laid-out x position.
func row_column(i: int) -> int:
	return int(round((_rows[i]["root"] as Control).position.x / (_ROW_W + _COL_GAP)))
