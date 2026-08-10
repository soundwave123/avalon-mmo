class_name MailOps
extends RefCounted
const _RI = preload("res://scripts/rpc_intake.gd")  # T-754 shape guards

# T-613: master-owned mail coordinator. The world proximity-gates (mailbox is bundled onto the
# banker's existing "bank" service hub, world_rpc.gd _service_intent) and injects the item registry;
# this module resolves identity, validates, and commits. Fully static (like AuctionOps) — the only
# per-process state is MailStore's in-memory rate-limit window, which lives in the store on purpose.

const _CM := preload("res://scripts/character_manager.gd")
const _IL := preload("res://scripts/inventory_logic.gd")
const _MS := preload("res://scripts/mail_store.gd")

const MAX_SUBJECT_LEN := 80
const MAX_BODY_LEN := 500


static func op(params: Dictionary) -> Dictionary:
	var cid := _char_id(str(params.get("username", "")))
	if cid < 0:
		return {"error": "unknown_character"}
	var registry: Dictionary = _RI.shaped(params, "item_registry", {})
	match str(params.get("action", "inbox")):
		"inbox":
			return _full_view(cid, registry)
		"read":
			return _read(cid, int(params.get("message_id", -1)), registry)
		"take":
			return _take(cid, int(params.get("message_id", -1)), registry)
		"delete":
			return _delete(cid, int(params.get("message_id", -1)), registry)
		"send":
			return _send(cid, params, registry)
		_:
			return {"error": "unknown_action"}


static func _char_id(username: String) -> int:
	if username == "":
		return -1
	_CM.ensure_character(username)
	var character := _CM.get_character(username)
	return int(character.get("id", -1)) if not character.is_empty() else -1


# gdlint: disable=max-returns
static func _send(cid: int, params: Dictionary, registry: Dictionary) -> Dictionary:
	var to_name := str(params.get("to_name", "")).strip_edges()
	if to_name == "":
		return {"error": "no_recipient"}
	var recipient := _CM.get_character(to_name)  # T-613: recipient must ALREADY exist — no
	# ensure_character here, so a typo never silently mints a bogus alt slot.
	if recipient.is_empty():
		return {"error": "unknown_recipient"}
	var to_cid := int(recipient["id"])
	if to_cid == cid:
		return {"error": "cannot_mail_self"}
	var coins := maxi(0, int(params.get("coins", 0)))
	var slot_index := int(params.get("slot_index", -1))
	var requested_count := maxi(0, int(params.get("count", 0)))
	var subject := str(params.get("subject", "")).left(MAX_SUBJECT_LEN)
	var body := str(params.get("body", "")).left(MAX_BODY_LEN)
	var slots := _CM.get_inventory(cid)
	var item_id := ""
	var item_count := 0
	if slot_index >= 0 and requested_count > 0:
		var owned := {}
		for row: Dictionary in slots:
			if (
				str(row.get("slot_type", "")) == "bag"
				and int(row.get("slot_index", -1)) == slot_index
			):
				owned = row
				break
		if owned.is_empty():
			return {"error": "empty_slot"}
		item_id = str(owned["item_id"])
		if not registry.has(item_id):
			return {"error": "unknown_item"}
		item_count = mini(requested_count, int(owned.get("item_count", 0)))
		var removed := _IL.remove(slots, "bag", slot_index, item_count)
		if not bool(removed.get("ok", false)):
			return {"error": str(removed.get("reason", "remove_failed"))}
		slots = removed["slots"]
	if coins == 0 and item_id == "" and subject == "" and body == "":
		return {"error": "empty_mail"}
	# Fail-closed, pre-mutation validation (T-567 idiom): affordability is checked BEFORE anything
	# leaves the sender — a rejected send never partially executes.
	if coins > 0 and ServicesStore.get_coins(cid) < coins:
		return {"error": "insufficient_coins"}
	if not _MS.try_consume_send_slot(cid, Time.get_unix_time_from_system()):
		return {"error": "rate_limited"}
	if not _MS.commit_send(cid, slots, -coins, to_cid, subject, body, coins, item_id, item_count):
		return {"error": "persist_failed"}
	return {"ok": true, "sent": true, "coins": ServicesStore.get_coins(cid)}


static func _read(cid: int, message_id: int, registry: Dictionary) -> Dictionary:
	if message_id < 0 or not _MS.mark_read(message_id, cid):
		return {"error": "no_such_message"}
	return _full_view(cid, registry)


# T-609/T-567 idiom: claim first, grant item, credit coins — a bag-full item grant REOPENS the
# claim (attachment stays put, retryable); a positive coin credit is treated as effectively
# infallible (the guarded UPDATE only rejects a negative balance, impossible here) so it is applied
# LAST and never reopened after — reopening post-credit would double-pay on a retry.
static func _take(cid: int, message_id: int, registry: Dictionary) -> Dictionary:
	if message_id < 0:
		return {"error": "bad_message_id"}
	var row := _MS.get_message(message_id, cid)
	if row.is_empty():
		return {"error": "no_such_message"}
	if bool(row["is_taken"]):
		return {"error": "already_taken"}
	if not _MS.claim_take(message_id, cid):
		return {"error": "already_taken"}
	var item_id := str(row["item_id"])
	var item_count := int(row["item_count"])
	if item_id != "" and item_count > 0:
		var granted := _CM.try_add_items(cid, [{"item_id": item_id, "count": item_count}], registry)
		if not bool(granted.get("ok", false)):
			_MS.reopen_take(message_id)  # nothing was granted — safe to retry later
			var out := _full_view(cid, registry)
			out["error"] = "bag_full"
			return out
	var coins := int(row["coins"])
	if coins > 0:
		ServicesStore.adjust_coins(cid, coins, _MS.REASON_MAIL_TAKE)
	var out := _full_view(cid, registry)
	out["taken_id"] = message_id
	return out


static func _delete(cid: int, message_id: int, registry: Dictionary) -> Dictionary:
	if message_id < 0 or not _MS.delete(message_id, cid):
		return {"error": "cannot_delete"}
	var out := _full_view(cid, registry)
	out["deleted_id"] = message_id
	return out


static func _full_view(cid: int, registry: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"inbox": _view_rows(_MS.inbox(cid)),
		"coins": ServicesStore.get_coins(cid),
		"bag": _bag_view(cid, registry),
	}


static func _view_rows(rows: Array) -> Array:
	var out: Array = []
	for row: Dictionary in rows:
		var sender := _CM.get_character_by_id(int(row["from_cid"]))
		var coins := int(row["coins"])
		var item_count := int(row["item_count"])
		(
			out
			. append(
				{
					"id": int(row["id"]),
					"from_name": str(sender.get("name", sender.get("username", "Unknown"))),
					"subject": str(row["subject"]),
					"body": str(row["body"]),
					"coins": coins,
					"item_id": str(row["item_id"]),
					"item_count": item_count,
					"sent_at": int(row["sent_at"]),
					"read": bool(row["is_read"]),
					"taken": bool(row["is_taken"]),
					"has_attachments": coins > 0 or item_count > 0,
				}
			)
		)
	return out


static func _bag_view(cid: int, registry: Dictionary) -> Array:
	var out: Array = []
	for row: Dictionary in _CM.get_inventory(cid):
		if str(row.get("slot_type", "")) != "bag":
			continue
		var item_id := str(row.get("item_id", ""))
		(
			out
			. append(
				{
					"slot_index": int(row.get("slot_index", -1)),
					"item_id": item_id,
					"item_count": int(row.get("item_count", 0)),
					"name": str((registry.get(item_id, {}) as Dictionary).get("name", "")),
				}
			)
		)
	return out
