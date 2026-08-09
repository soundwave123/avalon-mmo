class_name WardrobePanel
extends Control

# T-428: code-built wardrobe. It previews server-authored appearance/dye rows and sends only
# selection ids; ownership, slot compatibility, persistence, and every public paper-doll token stay
# authoritative on world/master. V is chat-focus-gated like the other routed panels.

const _SLOTS := ["head", "shoulders", "chest", "legs", "weapon", "offhand"]

var _send_fn: Callable = Callable()
var _is_typing_fn: Callable = Callable()
var _appearances: Array = []
var _dyes: Array = []
var _looks: Dictionary = {}
var _equipped: Array = []
var _selected_slot := "head"
var _selected_appearance := ""
var _selected_dye := ""

var _slots_box: HBoxContainer = null
var _appearance_option: OptionButton = null
var _dye_option: OptionButton = null
var _preview: RichTextLabel = null
var _hide_button: Button = null


func _ready() -> void:
	visible = false
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -320.0
	offset_right = 320.0
	offset_top = -240.0
	offset_bottom = 240.0
	theme = UiTheme.build()

	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.theme_type_variation = "SolidWindow"
	add_child(frame)
	frame.anchor_right = 1.0
	frame.anchor_bottom = 1.0

	var list := VBoxContainer.new()
	list.name = "List"
	list.add_theme_constant_override("separation", 8)
	frame.add_child(list)

	var title := Label.new()
	title.text = "Wardrobe  (V)"
	title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	list.add_child(title)

	_slots_box = HBoxContainer.new()
	_slots_box.name = "Slots"
	list.add_child(_slots_box)
	for slot: String in _SLOTS:
		var button := Button.new()
		button.text = slot.capitalize()
		button.pressed.connect(_select_slot.bind(slot))
		_slots_box.add_child(button)

	_appearance_option = OptionButton.new()
	_appearance_option.name = "Appearance"
	_appearance_option.item_selected.connect(func(_index): _option_changed())
	list.add_child(_appearance_option)

	_dye_option = OptionButton.new()
	_dye_option.name = "Dye"
	_dye_option.item_selected.connect(func(_index): _option_changed())
	list.add_child(_dye_option)

	_preview = RichTextLabel.new()
	_preview.name = "Preview"
	_preview.bbcode_enabled = true
	_preview.fit_content = true
	_preview.custom_minimum_size = Vector2(0.0, 180.0)
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.add_child(_preview)

	var actions := HBoxContainer.new()
	list.add_child(actions)
	var apply := Button.new()
	apply.text = "Apply look"
	apply.pressed.connect(_apply_selected)
	actions.add_child(apply)
	var clear := Button.new()
	clear.text = "Use equipped look"
	clear.pressed.connect(_clear_selected)
	actions.add_child(clear)
	_hide_button = Button.new()
	_hide_button.pressed.connect(_toggle_hide_helm)
	actions.add_child(_hide_button)
	_rebuild_controls()


func setup(send_fn: Callable, is_typing_fn: Callable, reply_router) -> void:
	_send_fn = send_fn
	_is_typing_fn = is_typing_fn
	if reply_router != null:
		reply_router.register("wardrobe_state", func(data): receive(data))
		reply_router.register("wardrobe_result", func(data): receive(data))


# T-571: returns the mounted instance so main.gd can fold it into the centralized Esc panel set
# (_open_hud_panels) — no panel drives its own Esc (the T-320 stuck-panel / SettingsEscGate idiom).
static func mount(
	hud: Node, send_fn: Callable, is_typing_fn: Callable, reply_router
) -> WardrobePanel:
	var panel := WardrobePanel.new()
	panel.name = "WardrobePanel"
	hud.add_child(panel)
	panel.setup(send_fn, is_typing_fn, reply_router)
	return panel


func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.is_pressed() or event.is_echo():
		return
	if UiInputGate.is_text_input_focused(get_viewport()):
		return
	var key := (event as InputEventKey).keycode
	# T-571 (report #28): Esc is NOT handled here — SettingsEscGate/main._handle_escape is the one
	# owner of Esc precedence (_open_hud_panels includes this panel). A local Escape branch here
	# raced main's central handler and could leave Options opening on top after this self-closed.
	if key != KEY_V or (_is_typing_fn.is_valid() and bool(_is_typing_fn.call())):
		return
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible:
		_emit({"type": "wardrobe_list"})


func receive(data: Dictionary) -> void:
	if str(data.get("type", "")) == "wardrobe_result":
		return
	_appearances = data.get("appearances", [])
	_dyes = data.get("dyes", [])
	_looks = data.get("looks", {})
	_equipped = data.get("slots", [])
	_load_saved_selection()
	_rebuild_controls()


func _select_for_test(slot: String, appearance_id: String, dye_id: String) -> void:
	_selected_slot = slot
	_selected_appearance = appearance_id
	_selected_dye = dye_id
	_rebuild_controls()


func _apply_selected() -> void:
	if _selected_appearance == "":
		return
	_emit(
		{
			"type": "wardrobe_apply",
			"slot": _selected_slot,
			"appearance_id": _selected_appearance,
			"dye_id": _selected_dye,
		}
	)


func _clear_selected() -> void:
	_emit({"type": "wardrobe_clear", "slot": _selected_slot})


func _toggle_hide_helm() -> void:
	_emit({"type": "wardrobe_hide_helm"})


func get_preview_text() -> String:
	return _preview.text if _preview != null else ""


func _select_slot(slot: String) -> void:
	_selected_slot = slot
	_load_saved_selection()
	_rebuild_controls()


func _load_saved_selection() -> void:
	var saved: Dictionary = _looks.get(_selected_slot, {})
	_selected_appearance = str(saved.get("appearance_id", ""))
	_selected_dye = str(saved.get("dye_id", ""))


func _rebuild_controls() -> void:
	if _appearance_option == null:
		return
	_appearance_option.clear()
	_add_option(_appearance_option, "Use equipped appearance", "")
	for look: Dictionary in _appearances:
		if str(look.get("slot", "")) != _selected_slot:
			continue
		_add_option(
			_appearance_option, str(look.get("name", "Unknown look")), str(look.get("id", ""))
		)
	_select_metadata(_appearance_option, _selected_appearance)
	_dye_option.clear()
	_add_option(_dye_option, "No dye", "")
	for dye: Dictionary in _dyes:
		_add_option(_dye_option, str(dye.get("name", "Unknown dye")), str(dye.get("id", "")))
	_select_metadata(_dye_option, _selected_dye)
	_render_preview()


func _option_changed() -> void:
	_selected_appearance = str(_appearance_option.get_selected_metadata())
	_selected_dye = str(_dye_option.get_selected_metadata())
	_render_preview()


func _render_preview() -> void:
	if _preview == null:
		return
	var lines: Array[String] = ["[b]Paper doll preview[/b]"]
	for slot: String in _SLOTS:
		var name := _equipped_name(slot)
		if slot == _selected_slot and _selected_appearance != "":
			name = _catalog_name(_appearances, _selected_appearance, name)
		lines.append("%s: %s" % [slot.capitalize(), name])
	if _selected_dye != "":
		lines.append("Dye: %s" % _catalog_name(_dyes, _selected_dye, _selected_dye))
	_preview.text = "\n".join(lines)
	var head: Dictionary = _looks.get("head", {})
	_hide_button.text = "Show helm" if bool(head.get("hidden", false)) else "Hide helm"


func _equipped_name(slot: String) -> String:
	for row: Dictionary in _equipped:
		if str(row.get("slot_type", "")) == slot:
			var display := str(row.get("name", ""))
			if display != "":
				return display
			# T-557: never surface the raw "itm_starter_sword" id — humanize it into a readable
			# label ("Starter Sword") when the row carries no server-supplied display name.
			return ItemNaming.humanize_item_id(str(row.get("item_id", "")), "Equipped")
	return "—"


static func _catalog_name(rows: Array, row_id: String, fallback: String) -> String:
	for row: Dictionary in rows:
		if str(row.get("id", "")) == row_id:
			return str(row.get("name", fallback))
	return fallback


static func _add_option(option: OptionButton, label: String, metadata: String) -> void:
	option.add_item(label)
	option.set_item_metadata(option.item_count - 1, metadata)


static func _select_metadata(option: OptionButton, metadata: String) -> void:
	for index in range(option.item_count):
		if str(option.get_item_metadata(index)) == metadata:
			option.select(index)
			return


func _emit(message: Dictionary) -> void:
	if _send_fn.is_valid():
		_send_fn.call(message)
