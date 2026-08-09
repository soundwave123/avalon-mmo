extends RefCounted

# T-450 world-side daily seam, carved out of world_rpc at its file/method cap. The world owns the
# content registry and UTC date fact; the master owns character claims/streak/rewards. Browse is
# reached only after world_rpc has validated NPC identity, service, and player proximity.

const _CQ := preload("res://scripts/content/content_query.gd")

var _master = null
var _reply: Callable = Callable()
var _quests: Dictionary = {}


func setup(master, reply: Callable, quests: Dictionary) -> void:
	_master = master
	_reply = reply
	_quests = quests


func browse(peer_id: int, username: String, npc_id: String, action: String) -> void:
	var daily: Dictionary = await (
		_master
		. call_master(
			"daily_status",
			{
				"username": username,
				"date_key": Time.get_date_string_from_system(true),
				"quest_defs": _CQ.all_quest_defs(_quests),
			}
		)
	)
	(
		_reply
		. call(
			peer_id,
			{
				"type": "service_ack",
				"ok": bool(daily.get("ok", false)),
				"reason": str(daily.get("reason", "")),
				"npc_id": npc_id,
				"service": "bounty",
				"action": action,
				"bounties": _CQ.bounty_defs(_quests),
				"daily": daily,
			}
		)
	)


func turn_in_context() -> Dictionary:
	return {
		"date_key": Time.get_date_string_from_system(true),
		"quest_defs": _CQ.all_quest_defs(_quests),
	}


# T-480: the weekly vault intent set this seam owns (proximity-free, like achievement_list —
# the master owns all state, so viewing/claiming needs no NPC and can never forge progress).
func handles(msg_type: String) -> bool:
	return msg_type == "weekly_op"


# T-480: weekly vault status/claim. The world stamps its UTC date fact (the T-450 discipline —
# pure master modules never read OS time) and passes only the validated session's username.
func weekly(peer_id: int, username: String, data: Dictionary) -> void:
	var result: Dictionary = await (
		_master
		. call_master(
			"weekly_op",
			{
				"username": username,
				"action": str(data.get("action", "status")),
				"choice": str(data.get("choice", "")),
				"date_key": Time.get_date_string_from_system(true),
			}
		)
	)
	result["type"] = "weekly_state"
	_reply.call(peer_id, result)
