extends GutTest

# T-613: the mail system. Attachments are escrow — held IN the mail row from send until taken; a
# failed take (bag full) must retain them, never destroy them, and a take must never double-grant.

const _IL = preload("res://scripts/inventory_logic.gd")
# CharacterManager has no class_name (deliberately — every caller aliases it, per vendor_ops.gd /
# test_vendor_ops.gd's own const); MailOps/MailStore/ServicesStore DO have class_name so they
# resolve as bare globals.
const CharacterManager = preload("res://scripts/character_manager.gd")

const REG := {
	"itm_iron_sword": {"name": "Iron Sword", "slot": "weapon", "stackable": false, "max_stack": 1},
	"itm_wolf_pelt": {"name": "Wolf Pelt", "slot": "none", "stackable": true, "max_stack": 20},
}


func before_each() -> void:
	CharacterManager.reset_for_test()


func _cid(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func _send(username: String, extra: Dictionary) -> Dictionary:
	var params := {"username": username, "action": "send", "item_registry": REG}
	params.merge(extra, true)
	return MailOps.op(params)


func _inbox(username: String) -> Dictionary:
	return MailOps.op({"username": username, "action": "inbox", "item_registry": REG})


func _give_sword(username: String) -> void:
	var cid := _cid(username)
	CharacterManager.try_add_items(cid, [{"item_id": "itm_iron_sword", "count": 1}], REG)


# ---- send/receive round trip ----------------------------------------------------------------


func test_send_receive_round_trip_coins_and_item() -> void:
	_cid("alice")
	_cid("bob")
	_give_sword("alice")
	var res := _send(
		"alice",
		{
			"to_name": "bob",
			"subject": "Gift",
			"body": "Enjoy!",
			"coins": 10,
			"slot_index": 0,
			"count": 1,
		}
	)
	assert_true(res.get("ok", false), str(res))
	assert_eq(ServicesStore.get_coins(_cid("alice")), 90)  # started at 100, -10 escrowed

	var inbox := _inbox("bob")
	var rows: Array = inbox["inbox"]
	assert_eq(rows.size(), 1)
	assert_eq(str(rows[0]["from_name"]), "alice")
	assert_eq(str(rows[0]["subject"]), "Gift")
	assert_eq(int(rows[0]["coins"]), 10)
	assert_eq(str(rows[0]["item_id"]), "itm_iron_sword")
	assert_false(bool(rows[0]["taken"]))

	var take := (
		MailOps
		. op(
			{
				"username": "bob",
				"action": "take",
				"message_id": int(rows[0]["id"]),
				"item_registry": REG,
			}
		)
	)
	assert_true(take.get("ok", false), str(take))
	assert_eq(ServicesStore.get_coins(_cid("bob")), 110)  # 100 + 10 credited
	assert_eq(
		_IL.bag_item_counts(CharacterManager.get_inventory(_cid("bob"))).get("itm_iron_sword", 0), 1
	)
	# sword left alice's bag
	assert_eq(
		_IL.bag_item_counts(CharacterManager.get_inventory(_cid("alice"))).get("itm_iron_sword", 0),
		0
	)


func test_send_text_only_message_no_attachments() -> void:
	_cid("alice")
	_cid("bob")
	var res := _send("alice", {"to_name": "bob", "subject": "Hi", "body": "hello there"})
	assert_true(res.get("ok", false), str(res))
	var rows: Array = _inbox("bob")["inbox"]
	assert_eq(rows.size(), 1)
	assert_false(bool(rows[0]["has_attachments"]))


# ---- atomic send: reject never partially executes ---------------------------------------------


func test_send_insufficient_coins_is_rejected_with_no_partial() -> void:
	_cid("alice")
	_cid("bob")
	_give_sword("alice")
	var before := ServicesStore.get_coins(_cid("alice"))
	var res := _send("alice", {"to_name": "bob", "coins": 999, "slot_index": 0, "count": 1})
	assert_eq(str(res.get("error", "")), "insufficient_coins")
	# neither the coins nor the item moved
	assert_eq(ServicesStore.get_coins(_cid("alice")), before)
	assert_eq(
		_IL.bag_item_counts(CharacterManager.get_inventory(_cid("alice"))).get("itm_iron_sword", 0),
		1
	)
	assert_eq((_inbox("bob")["inbox"] as Array).size(), 0)


func test_send_missing_item_slot_is_rejected_with_no_partial() -> void:
	_cid("alice")
	_cid("bob")
	var before := ServicesStore.get_coins(_cid("alice"))
	var res := _send("alice", {"to_name": "bob", "coins": 5, "slot_index": 3, "count": 1})
	assert_eq(str(res.get("error", "")), "empty_slot")
	assert_eq(ServicesStore.get_coins(_cid("alice")), before)  # the 5 coins never left
	assert_eq((_inbox("bob")["inbox"] as Array).size(), 0)


func test_send_unknown_recipient_is_rejected() -> void:
	_cid("alice")
	var res := _send("alice", {"to_name": "nobody_here", "coins": 5})
	assert_eq(str(res.get("error", "")), "unknown_recipient")
	assert_eq(ServicesStore.get_coins(_cid("alice")), 100)


func test_send_to_self_is_rejected() -> void:
	_cid("alice")
	var res := _send("alice", {"to_name": "alice", "coins": 5})
	assert_eq(str(res.get("error", "")), "cannot_mail_self")


# ---- fail-closed take: bag-full retains the attachment ----------------------------------------


func test_take_bag_full_retains_attachment_and_is_retryable() -> void:
	_cid("alice")
	var bob_cid := _cid("bob")
	_give_sword("alice")
	var res := _send("alice", {"to_name": "bob", "coins": 7, "slot_index": 0, "count": 1})
	assert_true(res.get("ok", false), str(res))
	var message_id := int((_inbox("bob")["inbox"] as Array)[0]["id"])

	# fill bob's bag completely: a non-stackable item forces a fresh slot per unit (mirrors
	# test_character_manager.gd's test_try_add_items_bag_full_no_partial_write fill idiom).
	var fill: Array = []
	for i in range(_IL.BAG_SLOTS):
		fill.append({"item_id": "itm_iron_sword", "count": 1})
	var filled := CharacterManager.try_add_items(bob_cid, fill, REG)
	assert_true(filled["ok"], str(filled))
	assert_eq(CharacterManager.get_inventory(bob_cid).size(), _IL.BAG_SLOTS)

	var take := MailOps.op(
		{"username": "bob", "action": "take", "message_id": message_id, "item_registry": REG}
	)
	assert_eq(str(take.get("error", "")), "bag_full")
	# attachment retained: coins NOT credited, message still shows untaken
	assert_eq(ServicesStore.get_coins(bob_cid), 100)
	var still_there: Dictionary = (_inbox("bob")["inbox"] as Array)[0]
	assert_false(bool(still_there["taken"]))
	assert_eq(int(still_there["coins"]), 7)

	# free a slot and retry — now it lands
	CharacterManager.remove_item(bob_cid, "bag", 0)
	var retry := MailOps.op(
		{"username": "bob", "action": "take", "message_id": message_id, "item_registry": REG}
	)
	assert_true(retry.get("ok", false), str(retry))
	assert_eq(ServicesStore.get_coins(bob_cid), 107)


# ---- take-exactly-once idempotency --------------------------------------------------------------


func test_take_is_exactly_once() -> void:
	_cid("alice")
	var bob_cid := _cid("bob")
	_give_sword("alice")
	_send("alice", {"to_name": "bob", "coins": 10, "slot_index": 0, "count": 1})
	var message_id := int((_inbox("bob")["inbox"] as Array)[0]["id"])

	var first := MailOps.op(
		{"username": "bob", "action": "take", "message_id": message_id, "item_registry": REG}
	)
	assert_true(first.get("ok", false), str(first))
	assert_eq(ServicesStore.get_coins(bob_cid), 110)

	var second := MailOps.op(
		{"username": "bob", "action": "take", "message_id": message_id, "item_registry": REG}
	)
	assert_eq(str(second.get("error", "")), "already_taken")
	assert_eq(ServicesStore.get_coins(bob_cid), 110)  # no double credit
	assert_eq(
		_IL.bag_item_counts(CharacterManager.get_inventory(bob_cid)).get("itm_iron_sword", 0), 1
	)  # no double grant


# ---- delete: only once attachments are gone -----------------------------------------------------


func test_delete_blocked_until_attachments_taken_then_allowed() -> void:
	_cid("alice")
	_cid("bob")
	_give_sword("alice")
	_send("alice", {"to_name": "bob", "coins": 3, "slot_index": 0, "count": 1})
	var message_id := int((_inbox("bob")["inbox"] as Array)[0]["id"])

	var blocked := MailOps.op({"username": "bob", "action": "delete", "message_id": message_id})
	assert_eq(str(blocked.get("error", "")), "cannot_delete")
	assert_eq((_inbox("bob")["inbox"] as Array).size(), 1)

	MailOps.op(
		{"username": "bob", "action": "take", "message_id": message_id, "item_registry": REG}
	)
	var ok := MailOps.op({"username": "bob", "action": "delete", "message_id": message_id})
	assert_true(ok.get("ok", false), str(ok))
	assert_eq((_inbox("bob")["inbox"] as Array).size(), 0)


func test_delete_a_plain_message_with_no_attachments_needs_no_take() -> void:
	_cid("alice")
	_cid("bob")
	_send("alice", {"to_name": "bob", "subject": "hey", "body": "just saying hi"})
	var message_id := int((_inbox("bob")["inbox"] as Array)[0]["id"])
	var ok := MailOps.op({"username": "bob", "action": "delete", "message_id": message_id})
	assert_true(ok.get("ok", false), str(ok))


# ---- read marks it read (server counts UP) -------------------------------------------------------


func test_read_marks_message_read() -> void:
	_cid("alice")
	_cid("bob")
	_send("alice", {"to_name": "bob", "subject": "hey", "body": "hi"})
	var message_id := int((_inbox("bob")["inbox"] as Array)[0]["id"])
	assert_false(bool((_inbox("bob")["inbox"] as Array)[0]["read"]))
	var res := MailOps.op({"username": "bob", "action": "read", "message_id": message_id})
	assert_true(res.get("ok", false), str(res))
	assert_true(bool((_inbox("bob")["inbox"] as Array)[0]["read"]))


# ---- rate limit: modest, per-character ----------------------------------------------------------


func test_send_rate_limit_rejects_excess_sends() -> void:
	_cid("alice")
	_cid("bob")
	var sent_ok := 0
	var rejected := 0
	for i in range(MailStore.MAX_SENDS + 2):
		var res := _send("alice", {"to_name": "bob", "subject": "spam %d" % i})
		if res.get("ok", false):
			sent_ok += 1
		elif str(res.get("error", "")) == "rate_limited":
			rejected += 1
	assert_eq(sent_ok, MailStore.MAX_SENDS)
	assert_true(rejected > 0)
	assert_eq((_inbox("bob")["inbox"] as Array).size(), MailStore.MAX_SENDS)
