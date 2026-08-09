extends RefCounted
# T-293: expand a mob kill's threat-holders to party scope. Keeps world/main.gd lean — it snapshots
# live session state (positions from PlayerSessions, alive from each peer's CombatResources) and
# defers the pure eligibility rule to party_logic.credit_recipients. Party-mates who are alive and
# within PARTY_CREDIT_RADIUS of the corpse share the kill (so an elite bounty pays the whole group,
# not only who landed the tag); a dead or out-of-range mate does not.

const PlayerSessions = preload("res://scripts/player_sessions.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _PL = preload("res://scripts/party_logic.gd")

# Generous enough to cover an elite fight (leash ~24-34) so a ranged/healer member standing back
# still earns credit, tight enough that a straggler off in another zone does not.
const PARTY_CREDIT_RADIUS := 60.0


static func recipients(
	party_store: Dictionary, attackers: Array, combat_resources: Dictionary, mob_pos: Vector3
) -> Array:
	var positions: Dictionary = {}
	var alive: Array = []
	for pid in combat_resources:
		positions[pid] = PlayerSessions.get_player(pid).get("pos", Vector3.ZERO)
		if not _CR.is_dead(combat_resources[pid]):
			alive.append(pid)
	return _PL.credit_recipients(
		party_store, attackers, positions, alive, mob_pos, PARTY_CREDIT_RADIUS
	)
