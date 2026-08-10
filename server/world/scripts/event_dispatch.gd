extends RefCounted
# T-699: region-scoped broadcaster for combat/death/respawn events. Before T-699 every such event
# was an all-peers reliable rpc (main._broadcast) — O(events × CCU), cross-region (an Ashmoor player
# received every Wold swing). This narrows the recipient list to the SAME instance + era region the
# positions path already buckets by (broadcast_builder.region_of), UNION the involved players and
# their party-mates, so a cross-region party or the event's own target still gets it. The message
# shape and the client RPC it lands on (_receive_message) are UNCHANGED — only who receives it.

const _BB = preload("res://scripts/broadcast_builder.gd")

var _send_event: Callable  # (peer_id:int, data:Dictionary) -> void; rpc_id on _receive_message
var _positions: Callable  # () -> PlayerSessions.get_positions()
var _party_store: Dictionary = {}


func setup(send_event: Callable, positions: Callable, party_store: Dictionary) -> void:
	_send_event = send_event
	_positions = positions
	_party_store = party_store


# A combat/death event whose origin is derived from the first involved player's live position
# (player death/respawn/ability results always involve a positioned player).
func involving(data: Dictionary, involved: Array) -> void:
	_emit(data, involved, {})


# An event whose origin is an explicit world point (mob death/respawn — the mob is not a peer).
func at(data: Dictionary, iid: int, pos: Vector3, involved: Array) -> void:
	_emit(data, involved, {"iid": iid, "x": pos.x, "z": pos.z})


# The recap combat-event relay (ability_result / mob damage). caster_id/target_id are ints (a peer
# id for players, an entity_id for mobs — the non-peer ids drop out in event_recipients).
func combat(event: Dictionary) -> void:
	involving(event, [int(event.get("caster_id", -1)), int(event.get("target_id", -1))])


func _emit(data: Dictionary, involved: Array, origin: Dictionary) -> void:
	var recipients: Array = _BB.event_recipients(
		_positions.call(), involved, _party_store["party_of"], _party_store["parties"], origin
	)
	for pid in recipients:
		_send_event.call(int(pid), data)


# T-699: identical wire shape to the pre-T-699 main._check_death_player broadcast (recipient list
# only narrows). Kept here so main.gd stays under the gdlint max-file-lines cap.
#
# T-724: `wear_applied` is the server's verdict on whether this death actually cost durability
# (instance_service.on_player_died waives it inside the KIND_TRIAL tutorial capstone). The client
# gates its "Your gear was damaged." line on this flag and never re-derives the rule locally.
static func player_death(
	pid: int, player_name: String, max_hp: int, wear_applied: bool
) -> Dictionary:
	return {
		"type": "player_death",
		"peer_id": pid,
		"player_id": pid,
		"player_name": player_name,
		"target_name": player_name,
		"caster_name": "",
		"target_id": pid,
		"caster_id": "",
		"hp": 0,
		"max_hp": max_hp,
		"wear_applied": wear_applied,
	}


# T-749: the last event payload still built inline in main.gd, moved here beside its siblings for
# the same max-file-lines reason. Wire shape is byte-identical to the inline dict it replaces.
# `entity_id` is the _mobs KEY (what every client-side handler matches on); `credited` is the
# T-034/T-293 kill-credit list (threat-holders + party-mates) the quest matcher reads.
static func mob_death(entity_id: int, mob, credited: Array) -> Dictionary:
	return {
		"type": "mob_death",
		"mob_id": entity_id,
		"mob_name": mob.name,
		"target_id": entity_id,
		"target_name": mob.name,
		"caster_name": "",
		"caster_id": "",
		"hp": 0,
		"max_hp": mob.resources.max_hp,
		"credited_player_ids": credited,
		"mob_type_id": mob.mob_type_id,
	}


static func player_respawn(pid: int, player_name: String, max_hp: int) -> Dictionary:
	return {
		"type": "player_respawn",
		"peer_id": pid,
		"player_id": pid,
		"player_name": player_name,
		"target_name": player_name,
		"caster_name": "",
		"target_id": pid,
		"caster_id": "",
		"hp": max_hp,
		"max_hp": max_hp,
	}
