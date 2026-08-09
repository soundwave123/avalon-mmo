class_name ActionBar
# T-308: the combat action bar — one framed slot per kit ability, each with a 1-9 hotkey pip and a
# cooldown sweep. The client already learns the kit from the server's `class_kit` message
# (id/name/effect/cast/cost/range); it does NOT receive per-ability cooldown remaining, and
# abilities share only a server-side global cooldown (30 ticks = 1.5 s, server_config.gd). So the
# sweep here is an HONEST client-side GCD ESTIMATE started on press (doubling as the pressed-state
# feedback), not server truth — flagged as the known gap for a future server cooldown push.
# Slots/pips are built once; an update is anchor math only (no per-frame allocation — T-210).

extends Control

# T-422c: slots are drag SOURCES and drop TARGETS — the player drags an ability from one slot onto
# another to SWAP them (the hotkey number stays with the SLOT, so moving Frostbolt to slot 3 makes
# key 3 cast it). An ability dragged off the spellbook (source "book") onto a slot places it there
# (swapping with the occupant). Every reorder emits `layout_changed(ordered_ids)` so main relays a
# `set_bar_layout` intent (the server validates + persists) and re-orders its own cast map.

# T-731: each slot renders one of three states — READY (untouched art), ON-COOLDOWN (the sweep
# above), and INSUFFICIENT RESOURCE (art desaturated + dimmed by AbilityAffordance's shader). The
# third one is read from the ability's OWN declared cost against the class resource the snapshot
# reports, so rage, mana and any future resource work without a class switch. The two states
# compose: the sweep is drawn over the art, so cooldown wins visually while the dim stays under it.

signal layout_changed(ordered_ids: Array)

const GCD_SECONDS := 1.5  # server global cooldown estimate (server_config.gd: 30 ticks @ 20 Hz)
const MAX_SLOTS := 9  # hotkeys 1-9
# T-464: always show at least this many slots so future/empty slots are DISCOVERABLE — any slot past
# the current kit renders as a dim locked placeholder (a "+" glyph) so the bar never reads as "this
# is all you get". As the player learns abilities the locked count shrinks toward zero.
const MIN_VISIBLE_SLOTS := 6
const _SLOT := 52.0
const _ICON_DIR := "res://assets/icons/abilities/"  # T-422a: per-ability icon art (game-icons.net)

var _row: HBoxContainer = null
var _slots: Array = []  # each: {root:Panel, sweep:Panel, cd_end:int(ms), cd_dur:int(ms)}
var _locked_roots: Array = []  # T-464: dim placeholder panels for future/unlockable slots
var _active_cooldowns: int = 0
var _kit: Array = []  # T-422c: the ordered ability rows backing the slots (drag reorders this)
var _resource_kind: String = "mana"  # T-464: names the tooltip cost line (fed from update_vitals)
# T-731: own class-resource level from the latest snapshot, so a slot can render the WoW third
# state — INSUFFICIENT RESOURCE (desaturated + dimmed art), distinct from the cooldown sweep.
var _resource_cur: int = 0
var _resource_max: int = 0
var _tooltip: AbilityTooltip = null  # T-464: hover-a-slot tooltip (name/desc/cost/cooldown)
# T-697 fix 5: the two slot frame styleboxes, built once — trigger/expiry/drag-highlight used to
# allocate a fresh StyleBoxFlat per call (the cooldown sweep hit this every expiring slot).
var _slot_style: StyleBoxFlat = null
var _slot_style_pressed: StyleBoxFlat = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_row = HBoxContainer.new()
	_row.name = "SlotRow"
	_row.add_theme_constant_override("separation", 6)
	add_child(_row)
	# T-464: one shared hover tooltip (top_level, mouse-follow); slots show/hide it on enter/exit.
	_tooltip = AbilityTooltip.new()
	_tooltip.name = "AbilityTooltip"
	add_child(_tooltip)


# T-464: name the class resource so the tooltip cost line reads correctly (fed from update_vitals,
# matching the spellbook). Re-applies live so a class/resource change updates future tooltips.
func set_resource_kind(kind: String) -> void:
	if kind != "":
		_resource_kind = kind


# T-731: the live resource feed — player_hud.update_vitals calls this from the OWN row of every
# server snapshot, so the bar's insufficient-resource dim tracks rage building/decaying and mana
# regenerating with no polling of its own. Cheap by design: it only touches a slot's material when
# that slot's affordability actually flips.
func set_resource_state(kind: String, current: int, maximum: int) -> void:
	set_resource_kind(kind)
	_resource_cur = current
	_resource_max = maximum
	_refresh_affordance()


# Re-evaluate every slot against the current resource level. Called on each vitals tick and after a
# kit rebuild (new/reordered slots must not render a stale state for a frame).
func _refresh_affordance() -> void:
	for i in range(_slots.size()):
		if i >= _kit.size():
			continue
		var s: Dictionary = _slots[i]
		var affordable := AbilityAffordance.is_affordable(_kit[i], _resource_kind, _resource_cur)
		if bool(s["affordable"]) == affordable:
			continue
		s["affordable"] = affordable
		AbilityAffordance.apply(s["afford_mat"] as ShaderMaterial, affordable)


# Rebuild the bar from the class kit (Array of {id,name,...}). Slot count follows kit_size.
func set_kit(kit: Array) -> void:
	# T-555: resolve each ability to a DISTINCT icon before building slots (server data reuses slugs
	# for Pummel/Concussive Blow, so the bar drew duplicate glyphs). deduped() returns fresh copies,
	# so this doubles as the T-422c own-copy that drag reordering mutates without touching the caller.
	_kit = AbilityIcons.deduped(kit)
	for s in _slots:
		(s["root"] as Node).queue_free()
	_slots.clear()
	for r in _locked_roots:
		(r as Node).queue_free()
	_locked_roots.clear()
	_active_cooldowns = 0
	var count: int = mini(_kit.size(), MAX_SLOTS)
	for i in range(count):
		var ability: Dictionary = _kit[i]
		_slots.append(_build_slot(i, str(ability.get("name", "?")), str(ability.get("icon", ""))))
	# T-464: pad with dim locked placeholders up to MIN_VISIBLE_SLOTS so future slots are visible.
	var total: int = clampi(maxi(count, MIN_VISIBLE_SLOTS), count, MAX_SLOTS)
	for i in range(count, total):
		_locked_roots.append(_build_locked_slot(i))
	# center the bar on its content. 4.7 regression (HUD-judge find): the _ready preset's offset
	# recompute clobbered these when set_kit ran at the wrong moment — assert anchors explicitly
	# right before the offsets so the pair is atomic and engine-proof.
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = -(total * (_SLOT + 6.0)) / 2.0
	offset_right = -offset_left
	offset_top = -_SLOT - 88.0  # sit above the XP belt
	offset_bottom = offset_top + _SLOT
	# T-731: freshly built slots start READY — stamp the current resource level onto them so a kit
	# rebuild (login, drag reorder, trainer purchase) never shows a stale affordance.
	_refresh_affordance()


func _build_slot(index: int, ability_name: String, icon_slug: String) -> Dictionary:
	var root := Panel.new()
	root.name = "Slot%d" % (index + 1)
	root.custom_minimum_size = Vector2(_SLOT, _SLOT)
	root.add_theme_stylebox_override("panel", _slot_frame_stylebox(false))
	_row.add_child(root)
	# T-422c: this slot is a drag source + drop target. Forwarding binds the slot index so the shared
	# handlers know which slot the input belongs to (the slot Panel itself stays a dumb frame).
	root.set_drag_forwarding(
		_get_slot_drag.bind(index), _can_drop_slot.bind(index), _drop_slot.bind(index)
	)

	# T-422a: per-ability icon art (game-icons.net, CC-BY 3.0). When the slug resolves to a real
	# texture we show it; a missing/blank icon falls back to the first-letters TEXT glyph so nothing
	# breaks. Explicit FULL_RECT anchors (never set_anchors_preset on the visible frame — the 4.7
	# HUD-blank trap), inset a few px so the slot frame border still reads around the art.
	var art: Control = null
	var icon_tex: Texture2D = _load_icon(icon_slug)
	if icon_tex != null:
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.texture = icon_tex
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.anchor_left = 0.0
		icon.anchor_top = 0.0
		icon.anchor_right = 1.0
		icon.anchor_bottom = 1.0
		icon.offset_left = 4.0
		icon.offset_top = 4.0
		icon.offset_right = -4.0
		icon.offset_bottom = -4.0
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(icon)
		art = icon
	else:
		# ability glyph — first letters of the ability name (framed text fallback, no icon art).
		var glyph := Label.new()
		glyph.name = "Glyph"
		glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		glyph.text = _abbrev(ability_name)
		glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(glyph)
		art = glyph

	# T-731: the art (icon OR fallback glyph) carries the affordance material — one shared Shader,
	# per-slot params. Applied to the art only, so the frame + keybind pip stay fully legible when
	# the ability is unaffordable (WoW greys the face, not the keybind).
	var afford_mat := AbilityAffordance.make_material()
	art.material = afford_mat

	# 1-9 keybind pip, top-left, gold. T-464: high-contrast (black outline + shadow, T-396 model) so
	# the number reads over any bright icon art.
	root.add_child(_make_pip(index, UiTheme.GOLD_BRIGHT))

	# T-464: hover shows the ability tooltip (name / desc / cost / cooldown / keybind).
	root.mouse_entered.connect(_on_slot_hover.bind(index))
	root.mouse_exited.connect(_on_slot_unhover)

	# cooldown sweep — a dark overlay that covers the top `remaining` fraction of the slot.
	var sweep := Panel.new()
	sweep.name = "Cooldown"
	sweep.add_theme_stylebox_override("panel", _sweep_stylebox())
	sweep.set_anchors_preset(Control.PRESET_FULL_RECT)
	sweep.anchor_bottom = 0.0  # empty = no cooldown
	sweep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sweep.visible = false
	root.add_child(sweep)

	return {
		"root": root,
		"sweep": sweep,
		"cd_end": 0,
		"cd_dur": 0,
		"afford_mat": afford_mat,
		"affordable": true,  # T-731: cached so the per-snapshot pass only writes on a TRANSITION
	}


# T-697 fix 5: cached slot frame styleboxes (shared Resources — one instance styles every slot).
func _slot_frame_stylebox(pressed: bool) -> StyleBoxFlat:
	if _slot_style == null:
		_slot_style = UiTheme.slot_stylebox(false)
		_slot_style_pressed = UiTheme.slot_stylebox(true)
	return _slot_style_pressed if pressed else _slot_style


func _sweep_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	sb.set_corner_radius_all(3)
	return sb


# T-464: the keybind pip — the 1-9 hotkey number, top-left, with a black outline + drop shadow so it
# stays legible over bright/busy icon art (T-396 outlined-text HUD model; matches chat_panel).
func _make_pip(index: int, color: Color) -> Label:
	var pip := Label.new()
	pip.name = "Pip"
	pip.text = str(index + 1)
	pip.add_theme_color_override("font_color", color)
	pip.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	pip.add_theme_constant_override("outline_size", 4)
	pip.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	pip.add_theme_constant_override("shadow_offset_x", 1)
	pip.add_theme_constant_override("shadow_offset_y", 1)
	pip.position = Vector2(4.0, 1.0)
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return pip


# T-464: a dim, non-interactive placeholder for a future/unlockable slot. It carries the "+" plus a
# greyed keybind pip (the key it will bind) and shows a "locked" tooltip on hover, so a new player
# sees the bar will grow. Not a drag source/target — an empty slot holds no ability to move.
func _build_locked_slot(index: int) -> Panel:
	var root := Panel.new()
	root.name = "Locked%d" % (index + 1)
	root.custom_minimum_size = Vector2(_SLOT, _SLOT)
	root.modulate = Color(1, 1, 1, 0.5)  # the whole placeholder reads as dim/inactive
	root.add_theme_stylebox_override("panel", _slot_frame_stylebox(false))
	_row.add_child(root)

	var plus := Label.new()
	plus.name = "Plus"
	plus.set_anchors_preset(Control.PRESET_FULL_RECT)
	plus.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	plus.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	plus.text = "+"
	plus.add_theme_color_override("font_color", UiTheme.PARCHMENT_DIM)
	plus.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(plus)

	root.add_child(_make_pip(index, UiTheme.PARCHMENT_DIM))

	root.mouse_entered.connect(_on_locked_hover.bind(index))
	root.mouse_exited.connect(_on_slot_unhover)
	return root


func _on_slot_hover(slot: int) -> void:
	if _tooltip == null or slot < 0 or slot >= _kit.size():
		return
	_tooltip.show_ability(_kit[slot], _resource_kind, str(slot + 1))


func _on_locked_hover(index: int) -> void:
	if _tooltip != null:
		_tooltip.show_locked(str(index + 1))


func _on_slot_unhover() -> void:
	if _tooltip != null:
		_tooltip.hide_tooltip()


# Press feedback + start the GCD-estimate sweep on the slot the player just cast.
func trigger_slot(slot: int) -> void:
	if slot < 0 or slot >= _slots.size():
		return
	var s: Dictionary = _slots[slot]
	var now := Time.get_ticks_msec()
	s["cd_dur"] = int(GCD_SECONDS * 1000.0)
	s["cd_end"] = now + s["cd_dur"]
	# Cover the whole icon at the instant of the cast; _process recedes it as the cooldown elapses.
	# (Setting it here — not waiting for the first _process — avoids a one-frame empty-sweep flash.)
	(s["sweep"] as Panel).anchor_bottom = 1.0
	(s["sweep"] as Panel).visible = true
	(s["root"] as Panel).add_theme_stylebox_override("panel", _slot_frame_stylebox(true))
	_active_cooldowns += 1
	set_process(true)


func _process(_delta: float) -> void:
	if _active_cooldowns <= 0:
		set_process(false)
		return
	var now := Time.get_ticks_msec()
	var still_active := 0
	for s in _slots:
		if int(s["cd_dur"]) <= 0:
			continue
		var remaining := int(s["cd_end"]) - now
		if remaining <= 0:
			(s["sweep"] as Panel).visible = false
			(s["sweep"] as Panel).anchor_bottom = 0.0
			(s["root"] as Panel).add_theme_stylebox_override("panel", _slot_frame_stylebox(false))
			s["cd_dur"] = 0
			continue
		# cover the top `remaining` fraction; the wipe recedes as the cooldown elapses.
		(s["sweep"] as Panel).anchor_bottom = clampf(
			float(remaining) / float(s["cd_dur"]), 0.0, 1.0
		)
		still_active += 1
	_active_cooldowns = still_active


# T-422a: resolve an icon slug to its texture, or null when there's no art (blank slug or missing
# file) so the caller falls back to the text glyph. ResourceLoader.exists avoids a load-error spam
# on an unmapped ability.
func _load_icon(icon_slug: String) -> Texture2D:
	if icon_slug.is_empty():
		return null
	var path := _ICON_DIR + icon_slug + ".png"
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _abbrev(ability_name: String) -> String:
	var words := ability_name.split(" ", false)
	if words.is_empty():
		return "?"
	if words.size() == 1:
		return words[0].substr(0, 3).capitalize()
	return (str(words[0][0]) + str(words[1][0])).to_upper()


# ---- T-422c drag-to-rebind ----------------------------------------------------


# Drag SOURCE: lift the slot's ability. Returns the drag payload (or null on an empty slot), and
# sets a semi-transparent preview that follows the cursor (2026 drag UX — the icon "lifts").
func _get_slot_drag(_at_position: Vector2, slot: int) -> Variant:
	if slot < 0 or slot >= _kit.size():
		return null
	var ability: Dictionary = _kit[slot]
	set_drag_preview(_drag_preview(str(ability.get("icon", "")), str(ability.get("name", "?"))))
	return {"source": "bar", "slot": slot, "ability_id": int(ability.get("id", -1))}


# Drop TARGET: accept a lifted ability from a bar slot or the spellbook.
func _can_drop_slot(_at_position: Vector2, data: Variant, _slot: int) -> bool:
	return data is Dictionary and str((data as Dictionary).get("source", "")) in ["bar", "book"]


func _drop_slot(_at_position: Vector2, data: Variant, slot: int) -> void:
	var d: Dictionary = data
	if str(d.get("source", "")) == "bar":
		swap_slots(int(d.get("slot", -1)), slot)
	else:  # from the spellbook — place that ability into this slot (swap with the occupant)
		place_ability_at(int(d.get("ability_id", -1)), slot)


# Swap two slots in the model and rebuild. The hotkey pip is the slot NUMBER, so it stays put — the
# ability underneath moves. Emits the new id order for main to relay + re-map its cast slots.
func swap_slots(i: int, j: int) -> void:
	if i < 0 or j < 0 or i >= _kit.size() or j >= _kit.size() or i == j:
		return
	var tmp: Variant = _kit[i]
	_kit[i] = _kit[j]
	_kit[j] = tmp
	set_kit(_kit)
	layout_changed.emit(ability_id_order())


# Move the ability with `ability_id` (already in the kit) into `slot`, swapping with the occupant.
func place_ability_at(ability_id: int, slot: int) -> void:
	for i in range(_kit.size()):
		if int((_kit[i] as Dictionary).get("id", -1)) == ability_id:
			swap_slots(i, slot)
			return


func ability_id_order() -> Array:
	var out: Array = []
	for ab in _kit:
		out.append(int((ab as Dictionary).get("id", -1)))
	return out


func ability_id_at(slot: int) -> int:
	if slot < 0 or slot >= _kit.size():
		return -1
	return int((_kit[slot] as Dictionary).get("id", -1))


# A lifted-icon drag preview: the ability icon (or its text glyph) at ~70% opacity, centered on the
# cursor so it reads as picked up off the bar.
func _drag_preview(icon_slug: String, ability_name: String) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex := _load_icon(icon_slug)
	var face: Control
	if tex != null:
		var icon := TextureRect.new()
		icon.texture = tex
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		face = icon
	else:
		var glyph := Label.new()
		glyph.text = _abbrev(ability_name)
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		face = glyph
	face.size = Vector2(_SLOT, _SLOT)
	face.position = Vector2(-_SLOT / 2.0, -_SLOT / 2.0)  # center on the cursor
	face.modulate = Color(1, 1, 1, 0.7)  # the "lift"
	holder.add_child(face)
	return holder


# Highlight every drop-eligible slot while a valid drag is in flight (NOTIFICATION_DRAG_BEGIN/END).
func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		var data: Variant = get_viewport().gui_get_drag_data()
		if data is Dictionary and str((data as Dictionary).get("source", "")) in ["bar", "book"]:
			_set_all_highlight(true)
	elif what == NOTIFICATION_DRAG_END:
		_set_all_highlight(false)


func _set_all_highlight(on: bool) -> void:
	for s in _slots:
		(s["root"] as Panel).add_theme_stylebox_override("panel", _slot_frame_stylebox(on))


# ---- headless-test accessors --------------------------------------------
func slot_count() -> int:
	return _slots.size()


# T-464: number of dim locked/future placeholder slots currently rendered.
func locked_slot_count() -> int:
	return _locked_roots.size()


# T-464: the keybind pip's outline thickness in a slot (0 when unstyled) — proves high-contrast.
func pip_outline_size(slot: int) -> int:
	if slot < 0 or slot >= _slots.size():
		return 0
	var pip := (_slots[slot]["root"] as Node).get_node("Pip") as Label
	return pip.get_theme_constant("outline_size")


# T-464: fraction of the slot the cooldown sweep currently covers (0 = ready, ~1 = just fired).
func sweep_fraction(slot: int) -> float:
	if slot < 0 or slot >= _slots.size():
		return 0.0
	return (_slots[slot]["sweep"] as Panel).anchor_bottom


# T-464: build the tooltip text for a filled slot (proves name/cost/cooldown reach the tooltip).
func slot_tooltip_text(slot: int) -> String:
	if slot < 0 or slot >= _kit.size():
		return ""
	return AbilityTooltip.build_text(_kit[slot], _resource_kind, str(slot + 1))


# T-731: how the slot art is actually being painted right now — {desaturation, dim} straight off the
# live shader params (0/1 = untouched READY art). One accessor rather than three: ActionBar sits
# against the 20-public-method lint cap.
func slot_shading(slot: int) -> Dictionary:
	if slot < 0 or slot >= _slots.size():
		return {"desaturation": 0.0, "dim": 1.0}
	var mat := _slots[slot]["afford_mat"] as ShaderMaterial
	return {
		"desaturation": float(mat.get_shader_parameter("desaturation")),
		"dim": float(mat.get_shader_parameter("dim")),
	}


# T-731: the composed three-state render, named. "cooldown" leads because its sweep is drawn OVER
# the art, but an unaffordable ability still reports the dim underneath it.
func slot_visual_state(slot: int) -> String:
	if slot < 0 or slot >= _slots.size():
		return ""
	var on_cd := is_slot_on_cooldown(slot)
	var poor := not bool(_slots[slot]["affordable"])
	if on_cd and poor:
		return "cooldown+insufficient"
	if on_cd:
		return "cooldown"
	if poor:
		return "insufficient"
	return "ready"


func hotkey_label(slot: int) -> String:
	if slot < 0 or slot >= _slots.size():
		return ""
	return ((_slots[slot]["root"] as Node).get_node("Pip") as Label).text


func is_slot_on_cooldown(slot: int) -> bool:
	if slot < 0 or slot >= _slots.size():
		return false
	return int(_slots[slot]["cd_dur"]) > 0


# T-422a: the icon texture rendered in a slot, or null when it fell back to the text glyph.
func slot_icon_texture(slot: int) -> Texture2D:
	if slot < 0 or slot >= _slots.size():
		return null
	var root := _slots[slot]["root"] as Node
	if root.has_node("Icon"):
		return (root.get_node("Icon") as TextureRect).texture
	return null


# T-422a: the fallback text-glyph string in a slot, or "" when the icon rendered instead.
func slot_glyph_text(slot: int) -> String:
	if slot < 0 or slot >= _slots.size():
		return ""
	var root := _slots[slot]["root"] as Node
	if root.has_node("Glyph"):
		return (root.get_node("Glyph") as Label).text
	return ""
