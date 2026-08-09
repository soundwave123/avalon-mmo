# T-024: Threat table — per-entity threat tracking for mob target selection.
#
# Pure data structure — no OS time, no global state, no engine calls.
# Store threat as int consistently (damage is int, GUT int != float).
# Always use .get(key, default) — Godot 4.6 errors on dict[key] for missing keys.
#
# mob_id -> { attacker_id -> threat_amount }
# Each mob has an independent threat context.

class_name ThreatTable

extends RefCounted

var _table: Dictionary  # mob_id (int) -> { attacker_id (int) -> threat (int) }


func add_threat(mob_id: int, attacker_id: int, amount: int) -> void:
	var mob_threat: Dictionary = _table.get(mob_id, {})
	var current: int = mob_threat.get(attacker_id, 0)
	mob_threat[attacker_id] = current + amount
	_table[mob_id] = mob_threat


func get_threat(mob_id: int, attacker_id: int) -> int:
	var mob_threat: Dictionary = _table.get(mob_id, {})
	return mob_threat.get(attacker_id, 0)


func get_top_threat_target(mob_id: int) -> int:
	var mob_threat: Dictionary = _table.get(mob_id, {})
	if mob_threat.is_empty():
		return -1

	var top_id: int = -1
	var top_amount: int = -1
	for attacker_id in mob_threat:
		var threat: int = mob_threat[attacker_id]
		if threat > top_amount:
			top_amount = threat
			top_id = attacker_id
	return top_id


func taunt(mob_id: int, taunter_id: int) -> void:
	# T-063: WoW taunt — force the taunter to the top of this mob's threat so it switches target to
	# them. Adds just enough to sit one above the highest OTHER attacker (no-op if already on top).
	var highest_other: int = 0
	for attacker_id in get_attackers(mob_id):
		if attacker_id != taunter_id:
			highest_other = maxi(highest_other, get_threat(mob_id, attacker_id))
	var current: int = get_threat(mob_id, taunter_id)
	if current <= highest_other:
		add_threat(mob_id, taunter_id, (highest_other - current) + 1)


func get_attackers(mob_id: int) -> Array:
	# T-034: every attacker that dealt threat to this mob = the players credited with the kill.
	return _table.get(mob_id, {}).keys()


func clear_mob(mob_id: int) -> void:
	_table.erase(mob_id)


func remove_attacker(mob_id: int, attacker_id: int) -> void:
	var mob_threat: Dictionary = _table.get(mob_id, {})
	mob_threat.erase(attacker_id)
	if mob_threat.is_empty():
		_table.erase(mob_id)


# T-051: drop an attacker from EVERY mob's threat (on disconnect — a gone player must not hold aggro
# or be credited a kill via get_attackers).
func remove_attacker_everywhere(attacker_id: int) -> void:
	for mob_id: int in _table.keys():
		remove_attacker(mob_id, attacker_id)
