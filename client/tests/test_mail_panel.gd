extends GutTest
# T-613: the mailbox hub is built in code (service_panel.gd idiom) — headlessly unit-testable.
# These prove open() fires the inbox round-trip, on_ack renders inbox rows with the right action
# buttons (Read/Take/Delete gated on read/has_attachments/taken), the send form packs the injected
# extras (recipient/subject/body/coins/one bag item), and on_ack self-filters (never renders a
# sibling panel's ack). Live rendering is play-test-verified.

const MailPanel = preload("res://scripts/ui/mail_panel.gd")


class SendSpy:
	var sent: Array = []

	func intent(npc_id: String, action: String, extra: Dictionary) -> void:
		sent.append({"npc_id": npc_id, "action": action, "extra": extra})


func _panel() -> MailPanel:
	var p = MailPanel.new()
	add_child_autofree(p)
	return p


func _buttons(node: Node) -> Array:
	var out := []
	for child in node.get_children():
		if child is Button:
			out.append(child)
		out.append_array(_buttons(child))
	return out


func _inbox_ack(rows: Array, bag: Array = []) -> Dictionary:
	return {"ok": true, "inbox": rows, "coins": 100, "bag": bag}


func test_panel_builds_shell_hidden() -> void:
	var p = _panel()
	assert_false(p.visible, "starts hidden (opened from the bank body's Mailbox button)")
	assert_not_null(p._inbox_list, "inbox container")
	assert_not_null(p._to_edit, "recipient field")
	assert_not_null(p._item_picker, "bag item picker")


func test_open_shows_and_fires_inbox_round_trip() -> void:
	var p = _panel()
	var spy := SendSpy.new()
	p.setup_ex(spy.intent)
	p.open("npc_hk_banker")
	assert_true(p.visible)
	assert_eq(spy.sent.size(), 1)
	assert_eq(str(spy.sent[0]["action"]), "mail_inbox")
	assert_eq(str(spy.sent[0]["npc_id"]), "npc_hk_banker")


func test_on_ack_self_filters_on_inbox_key() -> void:
	# A sibling panel's ack (e.g. the bank's vault_list) carries no "inbox" key — must be ignored,
	# since main.gd forwards EVERY service_ack to this panel (service_panel.on_ack -> _mail.on_ack).
	var p = _panel()
	p.setup_ex(func(_n, _a, _e): pass)
	p.open("npc_hk_banker")
	p.on_ack({"ok": true, "vault": [], "coins": 100})
	assert_eq(p._inbox_list.get_child_count(), 0, "a non-mail ack never touches the inbox list")


func test_empty_inbox_shows_placeholder() -> void:
	var p = _panel()
	p.setup_ex(func(_n, _a, _e): pass)
	p.open("npc_hk_banker")
	p.on_ack(_inbox_ack([]))
	var texts := []
	for c in p._inbox_list.get_children():
		if c is Label:
			texts.append(c.text)
	assert_true(" ".join(texts).contains("empty"), "an empty inbox says so")


func test_unread_message_gets_a_read_button() -> void:
	var p = _panel()
	p.setup_ex(func(_n, _a, _e): pass)
	p.open("npc_hk_banker")
	(
		p
		. on_ack(
			_inbox_ack(
				[
					{
						"id": 1,
						"from_name": "alice",
						"subject": "Hi",
						"body": "",
						"coins": 0,
						"item_id": "",
						"item_count": 0,
						"read": false,
						"taken": false,
						"has_attachments": false,
					}
				]
			)
		)
	)
	var names: Array = (_buttons(p._inbox_list) as Array).map(func(b): return str(b.text))
	assert_true(names.has("Read"), "unread message offers Read")
	assert_true(names.has("Delete"), "a plain no-attachment message offers Delete without Take")
	assert_false(names.has("Take"), "no attachments -> no Take button")


func test_untaken_attachment_gets_a_take_button_not_delete() -> void:
	var p = _panel()
	p.setup_ex(func(_n, _a, _e): pass)
	p.open("npc_hk_banker")
	(
		p
		. on_ack(
			_inbox_ack(
				[
					{
						"id": 2,
						"from_name": "bob",
						"subject": "Gift",
						"body": "",
						"coins": 10,
						"item_id": "",
						"item_count": 0,
						"read": true,
						"taken": false,
						"has_attachments": true,
					}
				]
			)
		)
	)
	var names: Array = (_buttons(p._inbox_list) as Array).map(func(b): return str(b.text))
	assert_true(names.has("Take"), "an untaken attachment offers Take")
	assert_false(names.has("Delete"), "cannot delete until attachments are taken")
	assert_false(names.has("Read"), "already-read message offers no Read button")


func test_taken_attachment_gets_a_delete_button_not_take() -> void:
	var p = _panel()
	p.setup_ex(func(_n, _a, _e): pass)
	p.open("npc_hk_banker")
	(
		p
		. on_ack(
			_inbox_ack(
				[
					{
						"id": 3,
						"from_name": "bob",
						"subject": "Gift",
						"body": "",
						"coins": 10,
						"item_id": "",
						"item_count": 0,
						"read": true,
						"taken": true,
						"has_attachments": true,
					}
				]
			)
		)
	)
	var names: Array = (_buttons(p._inbox_list) as Array).map(func(b): return str(b.text))
	assert_true(names.has("Delete"), "a taken message can now be deleted")
	assert_false(names.has("Take"), "already taken -> no Take button")


func test_action_buttons_fire_with_message_id() -> void:
	var p = _panel()
	var spy := SendSpy.new()
	p.setup_ex(spy.intent)
	p.open("npc_hk_banker")
	(
		p
		. on_ack(
			_inbox_ack(
				[
					{
						"id": 42,
						"from_name": "bob",
						"subject": "Gift",
						"body": "",
						"coins": 10,
						"item_id": "",
						"item_count": 0,
						"read": false,
						"taken": false,
						"has_attachments": true,
					}
				]
			)
		)
	)
	spy.sent.clear()
	for b in _buttons(p._inbox_list):
		if str(b.text) == "Take":
			b.pressed.emit()
	assert_eq(spy.sent.size(), 1)
	assert_eq(str(spy.sent[0]["action"]), "mail_take")
	assert_eq(int(spy.sent[0]["extra"]["message_id"]), 42)


func test_send_form_packs_recipient_subject_coins_and_picked_item() -> void:
	var p = _panel()
	var spy := SendSpy.new()
	p.setup_ex(spy.intent)
	p.open("npc_hk_banker")
	p.on_ack(
		_inbox_ack(
			[],
			[{"slot_index": 3, "item_id": "itm_iron_sword", "item_count": 1, "name": "Iron Sword"}]
		)
	)
	p._to_edit.text = "bob"
	p._subject_edit.text = "Gift"
	p._body_edit.text = "enjoy"
	p._coins_edit.text = "15"
	p._item_picker.selected = 1  # index 0 is "(none)"; 1 is the one bag entry
	spy.sent.clear()
	p._on_send_pressed()
	assert_eq(spy.sent.size(), 1)
	var extra: Dictionary = spy.sent[0]["extra"]
	assert_eq(str(spy.sent[0]["action"]), "mail_send")
	assert_eq(str(extra["to_name"]), "bob")
	assert_eq(str(extra["subject"]), "Gift")
	assert_eq(int(extra["coins"]), 15)
	assert_eq(int(extra["slot_index"]), 3)
	assert_eq(int(extra["count"]), 1)


func test_send_form_with_no_recipient_does_not_send() -> void:
	var p = _panel()
	var spy := SendSpy.new()
	p.setup_ex(spy.intent)
	p.open("npc_hk_banker")
	spy.sent.clear()
	p._to_edit.text = "   "
	p._on_send_pressed()
	assert_eq(spy.sent.size(), 0, "a blank recipient never fires the send intent")


func test_close_hides_panel() -> void:
	var p = _panel()
	p.setup_ex(func(_n, _a, _e): pass)
	p.open("npc_hk_banker")
	p.close_panel()
	assert_false(p.visible)
