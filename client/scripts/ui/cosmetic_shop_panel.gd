class_name CosmeticShopPanel
extends Control

# T-476: the cosmetics store front (the BROWSE + BUY surface of the earn→spend loop). It reads the
# server-authored store board + the persisted cosmetic_currency balance from wardrobe_state, and
# sends only an appearance_id to buy; price, ownership, the balance debit, and every charter guard
# stay authoritative on world/master (docs/design/cosmetic-monetization-charter.md). H opens it
# (chat-focus-gated); B belongs to the Spellbook. No loot boxes, no timers, no fake discounts —
# a flat, honest catalog. Pairs with the Wardrobe (V): buy here, wear there.

var _send_fn: Callable = Callable()
var _is_typing_fn: Callable = Callable()
var _store: Array = []
var _owned: Array = []
var _balance := 0
var _selected := ""

var _balance_label: Label = null
var _item_option: OptionButton = null
var _detail: RichTextLabel = null
var _buy_button: Button = null


func _ready() -> void:
	visible = false
	anchor_left = 0.5
	anchor_top = 0.5
	anchor_right = 0.5
	anchor_bottom = 0.5
	offset_left = -300.0
	offset_right = 300.0
	offset_top = -220.0
	offset_bottom = 220.0
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
	title.text = "Cosmetics Store  (H)"
	title.add_theme_color_override("font_color", UiTheme.GOLD_BRIGHT)
	list.add_child(title)

	_balance_label = Label.new()
	_balance_label.name = "Balance"
	list.add_child(_balance_label)

	_item_option = OptionButton.new()
	_item_option.name = "Items"
	# T-569 (portal #23): an OptionButton defaults to FOCUS_ALL and, once clicked, retains viewport
	# GUI focus even after its popup closes — a well-known Godot gotcha where the still-focused
	# control then absorbs subsequent key presses, so H/L/etc. stop reaching main.gd's global
	# keybind handler until Escape. Same fix as chat_panel/talent_panel/guild_panel/social_panel/
	# onboarding_controller/trade_panel: FOCUS_NONE still lets mouse clicks open + select from the
	# dropdown, it just never lets the control become (or stay) the keyboard focus owner.
	_item_option.focus_mode = Control.FOCUS_NONE
	_item_option.item_selected.connect(func(_index): _option_changed())
	list.add_child(_item_option)

	_detail = RichTextLabel.new()
	_detail.name = "Detail"
	_detail.bbcode_enabled = true
	_detail.fit_content = true
	_detail.custom_minimum_size = Vector2(0.0, 140.0)
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.add_child(_detail)

	var actions := HBoxContainer.new()
	list.add_child(actions)
	_buy_button = Button.new()
	_buy_button.name = "Buy"
	_buy_button.text = "Buy"
	_buy_button.pressed.connect(_buy_selected)
	actions.add_child(_buy_button)
	_rebuild()


func setup(send_fn: Callable, is_typing_fn: Callable, reply_router) -> void:
	_send_fn = send_fn
	_is_typing_fn = is_typing_fn
	if reply_router != null:
		reply_router.register("wardrobe_state", func(data): receive(data))


# T-571: returns the mounted instance so main.gd can fold it into the centralized Esc panel set
# (_open_hud_panels) — no panel drives its own Esc (the T-320 stuck-panel / SettingsEscGate idiom).
static func mount(
	hud: Node, send_fn: Callable, is_typing_fn: Callable, reply_router
) -> CosmeticShopPanel:
	var panel := CosmeticShopPanel.new()
	panel.name = "CosmeticShopPanel"
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
	if key != KEY_H or (_is_typing_fn.is_valid() and bool(_is_typing_fn.call())):
		return
	toggle()
	get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible:
		# The store board + balance ride the shared wardrobe_state; a list refresh fetches both.
		_emit({"type": "wardrobe_list"})


func receive(data: Dictionary) -> void:
	if str(data.get("type", "")) != "wardrobe_state":
		return
	_store = data.get("store", [])
	_owned = data.get("appearances", [])
	_balance = int(data.get("cosmetic_currency", 0))
	if _selected == "" and not _store.is_empty():
		_selected = str((_store[0] as Dictionary).get("id", ""))
	_rebuild()


func _buy_selected() -> void:
	if _selected == "" or _owns(_selected) or not _affordable(_selected):
		return
	_emit({"type": "wardrobe_buy", "appearance_id": _selected})


func _select_for_test(appearance_id: String) -> void:
	_selected = appearance_id
	_rebuild()


func get_detail_text() -> String:
	return _detail.text if _detail != null else ""


func get_balance_text() -> String:
	return _balance_label.text if _balance_label != null else ""


func _option_changed() -> void:
	_selected = str(_item_option.get_selected_metadata())
	_render_detail()


func _rebuild() -> void:
	if _item_option == null:
		return
	_item_option.clear()
	for look: Dictionary in _store:
		var id := str(look.get("id", ""))
		var label := "%s — %d" % [str(look.get("name", id)), int(look.get("price", 0))]
		if _owns(id):
			label += "  (owned)"
		_item_option.add_item(label)
		_item_option.set_item_metadata(_item_option.item_count - 1, id)
	_select_metadata(_item_option, _selected)
	_render_detail()


func _render_detail() -> void:
	if _detail == null:
		return
	_balance_label.text = "Balance: %d cosmetic currency" % _balance
	var look := _find(_store, _selected)
	if look.is_empty():
		_detail.text = "[i]Nothing selected[/i]"
		_buy_button.disabled = true
		return
	var lines: Array[String] = [
		"[b]%s[/b]" % str(look.get("name", _selected)),
		"Slot: %s" % str(look.get("slot", "")),
		"Price: %d" % int(look.get("price", 0)),
	]
	if _owns(_selected):
		lines.append("[color=#8a8]Owned — wear it in the wardrobe (V).[/color]")
		_buy_button.disabled = true
	elif not _affordable(_selected):
		lines.append("[color=#c88]Not enough cosmetic currency yet.[/color]")
		_buy_button.disabled = true
	else:
		_buy_button.disabled = false
	_detail.text = "\n".join(lines)


func _owns(appearance_id: String) -> bool:
	return not _find(_owned, appearance_id).is_empty()


func _affordable(appearance_id: String) -> bool:
	var look := _find(_store, appearance_id)
	return not look.is_empty() and _balance >= int(look.get("price", 0))


static func _find(rows: Array, row_id: String) -> Dictionary:
	for row: Dictionary in rows:
		if str(row.get("id", "")) == row_id:
			return row
	return {}


static func _select_metadata(option: OptionButton, metadata: String) -> void:
	for index in range(option.item_count):
		if str(option.get_item_metadata(index)) == metadata:
			option.select(index)
			return


func _emit(message: Dictionary) -> void:
	if _send_fn.is_valid():
		_send_fn.call(message)
