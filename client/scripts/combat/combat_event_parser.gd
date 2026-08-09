class_name CombatEventParser
# T-027: Parse server combat event dicts into typed CombatEvent objects.
#
# Pure utility — no scene tree, no side effects.
# Accepts raw server Dictionary payloads (from ENet broadcast) and emits
# typed events via signals. The CombatFeedback orchestrator consumes these
# signals.
#
# Server → Client contract (field names/types):
#   ability_result: {type, ability_id:int, caster_id:int, caster_name:str,
#                    target_id:int, target_name:str, damage:int, outcome:str,
#                    target_hp:int, target_max_hp:int}
#   heal_result:    {type, caster_id:int, caster_name:str,
#                    target_id:int, target_name:str, amount:int,
#                    target_hp:int, target_max_hp:int}
#   player_death:   {type, player_id:int, player_name:str}
#   player_respawn: {type, player_id:int, player_name:str}
#   mob_death:      {type, mob_id:int, mob_name:str}
#   mob_respawn:    {type, mob_id:int, mob_name:str}
#   ability_rejected: {type, ability_id:int, reason:str, detail:dict}  (T-402: detail optional)

extends RefCounted

# ---- Typed event --------------------------------------------------------


class CombatEvent:
	"""Single parsed combat event — immutable value object."""
	var event_type: String = ""  # "ability_result" | "heal" | "player_death" | ...
	var caster_id: int = -1
	var caster_name: String = ""
	var target_id: int = -1
	var target_name: String = ""
	var damage: int = 0
	var outcome: String = "hit"
	var target_hp: int = -1
	var target_max_hp: int = -1
	var tick: int = -1  # Server tick at event time (for [tick=NNN] log ordering); -1 if absent
	var system_message: String = ""  # For death/respawn: "Player X died"
	var kind: String = ""  # T-586: damage-source tag ("" = combat; "falling" = fall landing)


# ---- Signals (consumed by CombatFeedback orchestrator) -------------------

signal ability_result_event(event: CombatEvent)
signal heal_event(event: CombatEvent)
signal player_death_event(event: CombatEvent)
signal player_respawn_event(event: CombatEvent)
signal mob_death_event(event: CombatEvent)
signal mob_respawn_event(event: CombatEvent)
# T-402 item 3: detail = server-computed context ({dist_m, range_m} on out_of_range; else {}).
signal ability_rejected_event(reason: String, detail: Dictionary)
signal cast_started_event(ability_id: int, cast_ticks: int)
signal cast_cancelled_event(reason: String)
signal unknown_event(data: Dictionary)

# ---- Parser state (tracks total events parsed for debugging) -------------

var _events_parsed: int = 0


func get_events_parsed() -> int:
	return _events_parsed


# ---- Main entry point ---------------------------------------------------


func parse(data: Dictionary) -> void:
	"""Parse a single raw server event dict. Emits exactly one typed signal."""
	if data == null or data.is_empty():
		return

	var msg_type: String = str(data.get("type", ""))

	match msg_type:
		"ability_result":
			# T-072: the server sends heals AS ability_result with outcome "heal" (a
			# heal_result type is never emitted) — route them to the heal event so the
			# feedback layer renders green, not as damage.
			if str(data.get("outcome", "")) == "heal":
				_emit_heal(data)
			else:
				_emit_ability_result(data)
		"heal_result":
			_emit_heal(data)
		"player_death":
			_emit_player_death(data)
		"player_respawn":
			_emit_player_respawn(data)
		"mob_death":
			_emit_mob_death(data)
		"mob_respawn":
			_emit_mob_respawn(data)
		"ability_rejected":
			var detail_v: Variant = data.get("detail", {})
			var detail: Dictionary = detail_v if detail_v is Dictionary else {}
			ability_rejected_event.emit(str(data.get("reason", "unknown")), detail)
			return
		"cast_started":
			cast_started_event.emit(int(data.get("ability_id", -1)), int(data.get("cast_ticks", 0)))
			return
		"cast_cancelled":
			cast_cancelled_event.emit(str(data.get("reason", "unknown")))
			return
		_:
			unknown_event.emit(data)
			return

	_events_parsed += 1


# ---- Parsers (each maps raw dict → CombatEvent → signal) ----------------


func _emit_ability_result(data: Dictionary) -> void:
	var evt := CombatEvent.new()
	evt.event_type = "ability_result"
	evt.caster_id = int(data.get("caster_id", -1))
	evt.caster_name = str(data.get("caster_name", "Unknown"))
	evt.target_id = int(data.get("target_id", -1))
	evt.target_name = str(data.get("target_name", "Unknown"))
	evt.damage = int(data.get("damage", 0))
	evt.outcome = str(data.get("outcome", "hit"))
	if evt.outcome.is_empty():
		evt.outcome = "hit"
	evt.target_hp = int(data.get("target_hp", -1))
	evt.target_max_hp = int(data.get("target_max_hp", 0))
	evt.tick = int(data.get("tick", -1))
	evt.kind = str(data.get("kind", ""))  # T-586: "falling" tags environmental landings
	ability_result_event.emit(evt)


func _emit_heal(data: Dictionary) -> void:
	var evt := CombatEvent.new()
	evt.event_type = "heal"
	evt.caster_id = int(data.get("caster_id", -1))
	evt.caster_name = str(data.get("caster_name", "Unknown"))
	evt.target_id = int(data.get("target_id", -1))
	evt.target_name = str(data.get("target_name", "Unknown"))
	# T-072: heal amount arrives as "damage" on the ability_result path, "amount" on the
	# (reserved) heal_result path — accept both.
	evt.damage = int(data.get("amount", data.get("damage", 0)))
	evt.target_hp = int(data.get("target_hp", -1))
	evt.target_max_hp = int(data.get("target_max_hp", 0))
	heal_event.emit(evt)


func _emit_player_death(data: Dictionary) -> void:
	var evt := CombatEvent.new()
	evt.event_type = "player_death"
	evt.target_id = int(data.get("player_id", -1))
	evt.target_name = str(data.get("player_name", "Unknown"))
	evt.system_message = "%s has died." % evt.target_name
	player_death_event.emit(evt)


func _emit_player_respawn(data: Dictionary) -> void:
	var evt := CombatEvent.new()
	evt.event_type = "player_respawn"
	evt.target_id = int(data.get("player_id", -1))
	evt.target_name = str(data.get("player_name", "Unknown"))
	evt.system_message = "%s has respawned." % evt.target_name
	player_respawn_event.emit(evt)


func _emit_mob_death(data: Dictionary) -> void:
	var evt := CombatEvent.new()
	evt.event_type = "mob_death"
	evt.target_id = int(data.get("mob_id", -1))
	evt.target_name = str(data.get("mob_name", "Unknown"))
	evt.system_message = "%s has died." % evt.target_name
	mob_death_event.emit(evt)


func _emit_mob_respawn(data: Dictionary) -> void:
	var evt := CombatEvent.new()
	evt.event_type = "mob_respawn"
	evt.target_id = int(data.get("mob_id", -1))
	evt.target_name = str(data.get("mob_name", "Unknown"))
	evt.system_message = "%s has respawned." % evt.target_name
	mob_respawn_event.emit(evt)
