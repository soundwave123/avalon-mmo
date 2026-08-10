class_name MailPanel
extends Control

# T-613: the mailbox hub — inbox (list/read/take/delete) + a simple send form (recipient/subject/
# coins/one bag item). Opened from ServicePanel's bank body (a "Mailbox" button bundled onto the
# banker's existing "bank" service hub, world_rpc.gd/mail_service.gd — no new NPC). Built in CODE
# (no .tscn), same idiom as service_panel.gd: a dim backdrop + a centered SolidWindow, rebuilt from
# each server ack so the whole thing is headless-unit-testable.

const _HAS_ATTACHMENTS := "has_attachments"

var _send_intent_ex: Callable = Callable()  # Callable(npc_id, action, extra) -> void (→ ClientNet)
var _npc_id: String = ""
var _bag: Array = []  # last ack's sender-side bag view, for the item picker

var _title: Label = null
var _inbox_list: VBoxContainer = null
var _status: Label = null
var _to_edit: LineEdit = null
var _subject_edit: LineEdit = null
var _body_edit: LineEdit = null
var _coins_edit: LineEdit = null
var _item_picker: OptionButton = null


# `host` is the ServicePanel whose bank body gets the "Mailbox" button (T-613 bundling) — wiring
# it here (instead of a THIRD main.gd line) keeps main.gd's mount call to one line at its cap.
static func mount(hud: Node, send_intent_ex: Callable, host: ServicePanel) -> MailPanel:
	var panel := MailPanel.new()
	panel.name = "MailPanel"
	hud.add_child(panel)
	panel.setup_ex(send_intent_ex)
	host.setup_mail(panel)
	return panel


func setup_ex(send_intent_ex: Callable) -> void:
	_send_intent_ex = send_intent_ex


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	# T-759: the panel below requests the "SolidWindow" variation but no theme was ever in scope, so
	# the variation never resolved and the window rendered default Godot grey. Carry the shared theme.
	theme = UiTheme.build()
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.theme_type_variation = "SolidWindow"  # T-396: deliberate window = opaque opt-in
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(420.0, 0.0)
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	_title = Label.new()
	_title.text = "Mailbox"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 22)
	box.add_child(_title)

	# T-759: ~8 inbox rows (a Label + an action HBox each) overflowed the window off-screen. Cap the
	# inbox in a scroll so the compose form and Close below it stay reachable (service_panel idiom).
	var inbox_scroll := ScrollContainer.new()
	inbox_scroll.name = "MailInboxScroll"
	inbox_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inbox_scroll.custom_minimum_size = Vector2(420.0, 220.0)
	box.add_child(inbox_scroll)
	_inbox_list = VBoxContainer.new()
	_inbox_list.name = "MailInbox"
	_inbox_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inbox_list.add_theme_constant_override("separation", 4)
	inbox_scroll.add_child(_inbox_list)

	box.add_child(HSeparator.new())
	_build_compose(box)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color(0.6, 0.85, 0.6))
	box.add_child(_status)

	var close := Button.new()
	close.name = "MailClose"
	close.text = "Close"
	close.pressed.connect(close_panel)
	box.add_child(close)


func _build_compose(box: VBoxContainer) -> void:
	var heading := Label.new()
	heading.text = "Send Mail"
	heading.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	box.add_child(heading)

	_to_edit = _labeled_edit(box, "To (character name)", "MailTo")
	_subject_edit = _labeled_edit(box, "Subject", "MailSubject")
	_body_edit = _labeled_edit(box, "Message", "MailBody")
	_coins_edit = _labeled_edit(box, "Coins", "MailCoins")

	var item_row := HBoxContainer.new()
	box.add_child(item_row)
	var item_label := Label.new()
	item_label.text = "Item:"
	item_row.add_child(item_label)
	_item_picker = OptionButton.new()
	_item_picker.name = "MailItemPicker"
	_item_picker.add_item("(none)")
	item_row.add_child(_item_picker)

	var send_btn := Button.new()
	send_btn.name = "MailSend"
	send_btn.text = "Send"
	send_btn.pressed.connect(_on_send_pressed)
	box.add_child(send_btn)


func _labeled_edit(box: VBoxContainer, label_text: String, edit_name: String) -> LineEdit:
	var row := HBoxContainer.new()
	box.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(120.0, 0.0)
	row.add_child(label)
	var edit := LineEdit.new()
	edit.name = edit_name
	edit.custom_minimum_size = Vector2(220.0, 0.0)
	row.add_child(edit)
	return edit


# ServicePanel's bank body opens this (a "Mailbox" button bundled onto the same NPC).
func open(npc_id: String) -> void:
	_npc_id = npc_id
	_status.text = ""
	visible = true
	_emit("mail_inbox", {})


func close_panel() -> void:
	visible = false


# main._on_result forwards every service_ack here; only the mail actions (this panel's own
# "mail_*" intents) carry an "inbox" key, so a bank/vendor/auction ack from a sibling panel is a
# harmless no-op instead of a misrender.
func on_ack(data: Dictionary) -> void:
	if not visible or not data.has("inbox"):
		return
	if not bool(data.get("ok", false)):
		_status.text = "Mail error: %s" % str(data.get("reason", ""))
	elif data.has("sent"):
		_status.text = "Sent."
		_subject_edit.text = ""
		_body_edit.text = ""
		_coins_edit.text = ""
	elif data.has("taken_id"):
		_status.text = "Attachments claimed."
	elif data.has("deleted_id"):
		_status.text = "Deleted."
	_bag = data.get("bag", [])
	_render_inbox(data.get("inbox", []))
	_render_bag_picker()


func _render_inbox(rows: Array) -> void:
	for child in _inbox_list.get_children():
		_inbox_list.remove_child(child)
		child.queue_free()
	if rows.is_empty():
		var empty := Label.new()
		empty.text = "Your inbox is empty."
		_inbox_list.add_child(empty)
		return
	for row: Dictionary in rows:
		_add_inbox_row(row)


func _add_inbox_row(row: Dictionary) -> void:
	var message_id := int(row.get("id", -1))
	var line := Label.new()
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.custom_minimum_size = Vector2(380.0, 0.0)
	line.text = _row_summary(row)
	_inbox_list.add_child(line)

	var actions := HBoxContainer.new()
	_inbox_list.add_child(actions)
	if not bool(row.get("read", false)):
		_row_button(actions, "Read", message_id, "read", "MailRead")
	if bool(row.get(_HAS_ATTACHMENTS, false)) and not bool(row.get("taken", false)):
		_row_button(actions, "Take", message_id, "take", "MailTake")
	if not bool(row.get(_HAS_ATTACHMENTS, false)) or bool(row.get("taken", false)):
		_row_button(actions, "Delete", message_id, "delete", "MailDelete")


func _row_summary(row: Dictionary) -> String:
	var parts := ["From %s" % str(row.get("from_name", "Unknown"))]
	var subject := str(row.get("subject", ""))
	if subject != "":
		parts.append('"%s"' % subject)
	var coins := int(row.get("coins", 0))
	var item_id := str(row.get("item_id", ""))
	var item_count := int(row.get("item_count", 0))
	if coins > 0:
		parts.append("%dc" % coins)
	if item_id != "" and item_count > 0:
		parts.append("%s x%d" % [ItemNaming.display_name(item_id, ""), item_count])
	if bool(row.get("taken", false)):
		parts.append("(taken)")
	elif not bool(row.get(_HAS_ATTACHMENTS, false)) and str(row.get("body", "")) != "":
		parts.append("- %s" % str(row["body"]))
	return " ".join(parts)


func _row_button(
	parent: Control, text: String, message_id: int, action: String, node_name: String
) -> void:
	var btn := Button.new()
	btn.text = text
	btn.name = "%s%d" % [node_name, message_id]
	btn.pressed.connect(func(): _emit("mail_%s" % action, {"message_id": message_id}))
	parent.add_child(btn)


func _render_bag_picker() -> void:
	_item_picker.clear()
	_item_picker.add_item("(none)")
	for entry: Dictionary in _bag:
		var name := ItemNaming.display_name(
			str(entry.get("item_id", "")), str(entry.get("name", ""))
		)
		_item_picker.add_item("%s x%d" % [name, int(entry.get("item_count", 0))])


func _on_send_pressed() -> void:
	var to_name := _to_edit.text.strip_edges()
	if to_name == "":
		_status.text = "Name a recipient first."
		return
	var extra := {
		"to_name": to_name,
		"subject": _subject_edit.text,
		"body": _body_edit.text,
		"coins": maxi(0, int(_coins_edit.text)) if _coins_edit.text.is_valid_int() else 0,
	}
	var picked := _item_picker.selected  # index 0 == "(none)"
	if picked > 0 and picked - 1 < _bag.size():
		var entry: Dictionary = _bag[picked - 1]
		extra["slot_index"] = int(entry.get("slot_index", -1))
		extra["count"] = int(entry.get("item_count", 0))
	_emit("mail_send", extra)
	_status.text = "Sending..."


func _emit(action: String, extra: Dictionary) -> void:
	if _send_intent_ex.is_valid():
		_send_intent_ex.call(_npc_id, action, extra)
