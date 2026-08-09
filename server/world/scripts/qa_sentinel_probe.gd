extends RefCounted

# T-561: thin world <-> sentinel adapter. Snapshots live per-player state into the
# pure sentinel's observation contract and logs any anomalies. Lives OUTSIDE
# main.gd (which sits at the 1000-line cap) and OFF the pure detector (which stays
# engine-free and unit-tested). It reads and logs; it never mutates game state.

const _QASENT = preload("res://scripts/qa_sentinel.gd")
const _PS = preload("res://scripts/player_sessions.gd")
const OOC_TICKS := 100  # ~5s @ 20 ticks/s; last-combat older than this = out of combat

var _sentinel = _QASENT.new()


# OFF by default: returns a probe only when AVALON_QA_SENTINEL=1, else null. Lets
# the world opt in with a single `var` initializer and no _ready wiring.
static func boot():
	if OS.get_environment("AVALON_QA_SENTINEL").strip_edges() == "1":
		print("[world] qa_sentinel ENABLED (AVALON_QA_SENTINEL=1)")
		return new()
	return null


# Called once per SERVER TICK from the world. `resources` is peer_id ->
# CombatResources; `threat_table` answers who each mob is currently on.
func scan(now_tick: int, resources: Dictionary, mobs: Dictionary, threat_table) -> void:
	var observations: Array = []
	for pid in resources:
		var cr = resources[pid]
		var in_combat := now_tick - int(cr.last_combat_tick) < OOC_TICKS
		var attacked := _is_targeted(pid, mobs, threat_table)
		(
			observations
			. append(
				{
					"pid": pid,
					"hp": int(cr.hp),
					"max_hp": int(cr.max_hp),
					"pos": _PS.get_player(pid).get("pos", Vector3.ZERO),
					"in_combat": in_combat,
					"attacked_by_mob": attacked,
					# A plausible attacker (in combat or currently targeted) is a recorded
					# source; its absence is what makes a death "unattributed".
					"damage_source_recorded": in_combat or attacked,
				}
			)
		)
	for anomaly in _sentinel.observe(now_tick, observations):
		print(_sentinel.format_line(anomaly))


func _is_targeted(pid: int, mobs: Dictionary, threat_table) -> bool:
	for mob_id in mobs:
		if threat_table.get_top_threat_target(mob_id) == pid:
			return true
	return false
