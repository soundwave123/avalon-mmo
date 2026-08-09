extends RefCounted
# T-429: world-side lifecycle wrapper around the pure recap core. Identity is always injected from
# PlayerSessions by main.gd; the request carries no character, numbers, comparison, or share target.

const _RECAP = preload("res://scripts/combat/performance_recap.gd")
const _EVENT_BUILDER = preload("res://scripts/combat/combat_event_builder.gd")
const HISTORY_LIMIT := 5

var _send: Callable = Callable()
var _broadcast: Callable = Callable()
var _telemetry: Callable = Callable()
var _tick_rate: int = 20
var _active: Dictionary = {}  # peer_id -> {character,key,label,state}
var _history: Dictionary = {}  # character -> encounter_key -> Array[recap]
var _latest: Dictionary = {}  # character -> recap


func setup(
	send_to_peer: Callable,
	tick_rate: int,
	broadcast: Callable = Callable(),
	telemetry: Callable = Callable()
) -> void:
	_send = send_to_peer
	_tick_rate = maxi(1, tick_rate)
	_broadcast = broadcast
	_telemetry = telemetry


func relay_player_result(
	ability,
	caster_id: int,
	caster_name: String,
	target_id: int,
	target_mob,
	target_name: String,
	target_resources,
	execution,
	now_tick: int
) -> void:
	var target_is_mob: bool = target_mob != null
	var event: Dictionary = _EVENT_BUILDER.ability_result(
		ability.id,
		ability.name,
		caster_id,
		target_id,
		execution.damage_amount,
		execution.outcome,
		now_tick,
		caster_name,
		target_name,
		target_resources.hp,
		target_resources.max_hp,
		execution.mitigated_amount,
		execution.interrupt_landed
	)
	_emit_event(event)
	var key := str(target_mob.mob_type_id) if target_is_mob else "pvp"
	record_ability(
		event,
		caster_id,
		caster_name,
		target_id,
		"" if target_is_mob else target_name,
		key,
		target_name if target_is_mob else "Duel"
	)


func relay_mob_damage(
	mob,
	target_id: int,
	target_name: String,
	target_resources,
	amount: int,
	outcome: String,
	now_tick: int,
	extra: Dictionary
) -> void:
	# T-560: caster_id is an INT (a peer id for players, the mob's entity_id for a mob attacker) —
	# NOT the string mob_id. Passing mob.mob_id ("mob_training_effigy") here threw
	# "Cannot convert argument 3 from String to int" on EVERY mob-on-player hit, crashing the recap
	# relay game-wide and masking real mob damage as "0 taken". The mob's string identity already
	# rides caster_name (mob.name); entity_id is the same int used as "mob_id" in the world broadcast.
	var event: Dictionary = _EVENT_BUILDER.ability_result(
		0,
		str(extra.get("weapon", "Basic Attack")),
		mob.entity_id,
		target_id,
		amount,
		outcome,
		now_tick,
		mob.name,
		target_name,
		target_resources.hp,
		target_resources.max_hp,
		int(extra.get("mitigated", 0)),
		false
	)
	event["ranged"] = extra.get("ranged", false)
	event["weapon"] = str(extra.get("weapon", ""))
	_emit_event(event)
	record_ability(event, mob.entity_id, "", target_id, target_name, str(mob.mob_type_id), mob.name)


func _emit_event(event: Dictionary) -> void:
	if _broadcast.is_valid():
		_broadcast.call(event)


func handles(message_type: String) -> bool:
	return message_type == "performance_recap_request"


func handle(message_type: String, peer_id: int, character: String, now_tick: int) -> void:
	if not handles(message_type) or character.is_empty():
		return
	var recap: Dictionary = {}
	if _active.has(peer_id):
		var entry: Dictionary = _active[peer_id]
		var prior := history_for(character, str(entry["key"]))
		recap = _RECAP.finalize(
			entry["state"], str(entry["key"]), str(entry["label"]), now_tick, _tick_rate, prior
		)
	else:
		recap = _latest.get(character, {}).duplicate(true)
	if recap.is_empty():
		recap = _RECAP.finalize(
			_RECAP.blank(now_tick), "none", "No combat recorded", now_tick, _tick_rate, []
		)
	_reply(peer_id, recap)


func record_ability(
	event: Dictionary,
	caster_id: int,
	caster_character: String,
	target_id: int,
	target_character: String,
	encounter_key: String,
	encounter_label: String
) -> void:
	var now_tick := int(event.get("tick", 0))
	_record(caster_id, caster_character, event, encounter_key, encounter_label, now_tick)
	if target_id != caster_id:
		_record(target_id, target_character, event, encounter_key, encounter_label, now_tick)


func _record(
	peer_id: int,
	character: String,
	event: Dictionary,
	encounter_key: String,
	encounter_label: String,
	now_tick: int
) -> void:
	if peer_id <= 0 or character.is_empty():
		return
	var entry: Dictionary = (
		_active
		. get(
			peer_id,
			{
				"character": character,
				"key": encounter_key,
				"label": encounter_label,
				"state": _RECAP.blank(now_tick),
			}
		)
	)
	entry["character"] = character
	var current_key := str(entry["key"])
	var incoming_is_real := encounter_key != "support"
	var current_is_real := not current_key in ["", "support"]
	if current_is_real and incoming_is_real and current_key != encounter_key:
		# T-568: the active entry belongs to a DIFFERENT, already-resolved real encounter (e.g. the
		# training effigy) and a NEW real encounter has started (e.g. the wolf pack). Archive the
		# finished one to history/latest so its stats stop being contaminated by the new fight, then
		# start a clean entry for the new encounter — otherwise every subsequent hit keeps piling onto
		# the stale entry and the death recap keeps the FIRST encounter's label forever (reports #21/#22).
		_archive(character, entry["state"], current_key, str(entry["label"]), now_tick)
		entry = {
			"character": character,
			"key": encounter_key,
			"label": encounter_label,
			"state": _RECAP.blank(now_tick),
		}
	elif current_key in ["", "support"] and incoming_is_real:
		entry["key"] = encounter_key
		entry["label"] = encounter_label
	entry["state"] = _RECAP.apply_event(entry["state"], event, peer_id)
	_active[peer_id] = entry


func finish_target(
	target_id: int, encounter_key: String, encounter_label: String, now_tick: int
) -> void:
	var closing: Array[int] = []
	for peer_id in _active:
		var state: Dictionary = _active[peer_id]["state"]
		if peer_id == target_id or target_id in state.get("participant_ids", []):
			closing.append(peer_id)
	for peer_id in closing:
		_finish(peer_id, encounter_key, encounter_label, now_tick, true)


func finish_player_death(peer_id: int, character: String, now_tick: int) -> void:
	if not _active.has(peer_id):
		_active[peer_id] = {
			"character": character,
			"key": "pvp",
			"label": "Defeat",
			"state": _RECAP.blank(now_tick),
		}
	var entry: Dictionary = _active[peer_id]
	entry["state"] = _RECAP.apply_event(
		entry["state"], {"type": "player_death", "target_id": peer_id, "tick": now_tick}, peer_id
	)
	_active[peer_id] = entry
	finish_target(peer_id, str(entry["key"]), str(entry["label"]), now_tick)


func on_disconnect(peer_id: int, character: String, now_tick: int) -> void:
	if not _active.has(peer_id):
		return
	var entry: Dictionary = _active[peer_id]
	var key := str(entry.get("key", "session"))
	var label := str(entry.get("label", "Session"))
	entry["character"] = character
	_active[peer_id] = entry
	_finish(peer_id, key, label, now_tick, false)


func _finish(
	peer_id: int, encounter_key: String, encounter_label: String, now_tick: int, send_reply: bool
) -> void:
	if not _active.has(peer_id):
		return
	var entry: Dictionary = _active[peer_id]
	var character := str(entry["character"])
	var recap := _archive(character, entry["state"], encounter_key, encounter_label, now_tick)
	_active.erase(peer_id)
	if send_reply:
		_reply(peer_id, recap)


func _archive(
	character: String,
	state: Dictionary,
	encounter_key: String,
	encounter_label: String,
	now_tick: int
) -> Dictionary:
	# T-568: shared close-out path for a finished encounter — used both by explicit finishes
	# (finish_target/finish_player_death/on_disconnect) and by the mid-stream rollover in _record
	# when a new real encounter starts while the old one is still the active entry.
	var prior := history_for(character, encounter_key)
	var recap: Dictionary = _RECAP.finalize(
		state, encounter_key, encounter_label, now_tick, _tick_rate, prior
	)
	var by_content: Dictionary = _history.get(character, {}).duplicate(true)
	by_content[encounter_key] = _RECAP.append_history(prior, recap, HISTORY_LIMIT)
	_history[character] = by_content
	_latest[character] = recap.duplicate(true)
	if _telemetry.is_valid():
		_telemetry.call("performance_recap", character, character, recap.duplicate(true))
	return recap


func _reply(peer_id: int, recap: Dictionary) -> void:
	if _send.is_valid():
		_send.call(peer_id, {"type": "performance_recap", "recap": recap})


func history_for(character: String, encounter_key: String) -> Array:
	var by_content: Dictionary = _history.get(character, {})
	return (by_content.get(encounter_key, []) as Array).duplicate(true)
