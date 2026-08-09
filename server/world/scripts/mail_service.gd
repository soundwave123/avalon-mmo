extends RefCounted

# T-613: mail intent seam, carved out at world_rpc.gd's file-line cap (mirrors daily_service.gd's
# shape). The mailbox is bundled onto the banker's existing "bank" service hub — no new NPC
# service tag, no new proximity gate — world_rpc._service_intent has ALREADY validated known-npc,
# proximity, and service == "bank" before calling handle(); this module only builds the master op
# and turns the result into a service_ack (world owns the item registry; master owns mail state).

const _CQ := preload("res://scripts/content/content_query.gd")

const _ACTIONS := ["mail_inbox", "mail_read", "mail_take", "mail_delete", "mail_send"]

var _master = null
var _reply: Callable = Callable()
var _items: Dictionary = {}


func setup(master, reply: Callable, content_items: Dictionary) -> void:
	_master = master
	_reply = reply
	_items = content_items


func handles(action: String) -> bool:
	return action in _ACTIONS


func handle(
	peer_id: int, npc_id: String, username: String, action: String, data: Dictionary
) -> void:
	var op := {
		"username": username,
		"action": action.trim_prefix("mail_"),
		"message_id": int(data.get("message_id", -1)),
		"to_name": str(data.get("to_name", "")),
		"subject": str(data.get("subject", "")),
		"body": str(data.get("body", "")),
		"coins": int(data.get("coins", 0)),
		"slot_index": int(data.get("slot_index", -1)),
		"count": int(data.get("count", 1)),
		"item_registry": _CQ.item_registry(_items),
	}
	var result: Dictionary = await _master.call_master("mail_op", op)
	var ack := {
		"type": "service_ack",
		"ok": not result.has("error"),
		"npc_id": npc_id,
		"service": "bank",
		"action": action,
	}
	if result.has("error"):
		ack["reason"] = str(result["error"])
	for key in ["inbox", "bag", "coins", "sent", "taken_id", "deleted_id"]:
		if result.has(key):
			ack[key] = result[key]
	_reply.call(peer_id, ack)
