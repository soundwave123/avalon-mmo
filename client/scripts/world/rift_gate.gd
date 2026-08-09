# T-347: the ERA-RIFT threshold trigger — a pure, unit-testable proximity state machine (the
# crypt_gate.gd sibling; npc_wander/critter_wander tick style: no OS time, no engine access, caller
# injects the player's ground position). It watches TWO thresholds:
#   - "enter_era": player (in the crypt Vault, Era 1) touches the sealed era-rift monolith
#                  (T-344 prop @ ~(424.3,-45.3)) -> the crossing to Ashmoor 100 years on.
#   - "leave_era": player (in Ashmoor) touches the arrival monolith (@ ~(-420,-10)) -> the dev
#                  return (the fiction is one-way; a real return convenience is deferred).
# The server (instance_service.gd enter_era/leave_era) owns the teleport (a pure session move —
# Ashmoor is OPEN/SHARED, instance_id 0, NOT an instance alloc) and, eventually, the eligibility
# gate (T-335 quest completion — the flag is not server-queryable today, so the gate is a
# documented TODO for the T-352 quest chain). This module only FIRES the intent.
#
# Debounce mirrors crypt_gate: after a fire the matching point is HELD until the player walks back
# out of its radius, so touching a monolith fires exactly once. The server drops the traveller far
# from the fired monolith on both transitions, so the opposite hold is armed on the crossing.
extends RefCounted

# WORLD ground coords (server x, y == Godot global_position.x, .z).
# ENTER = the crypt Vault rift monolith (T-344 props.json tag hollowed_crypt_vault_rift).
# EXIT  = the Ashmoor arrival monolith (T-347 props.json tag ashmoor_arrival_rift).
const ENTER_POINT := Vector2(424.3, -45.3)
const EXIT_POINT := Vector2(-420.0, -10.0)
const RADIUS := 2.6

var in_ashmoor: bool = false
var _hold_enter: bool = false  # true while parked in the enter radius (blocks re-fire)
var _hold_exit: bool = false


# `p` = player ground position (Godot global_position.x, .z == server x, y).
# Returns "enter_era", "leave_era", or "" — the server intent to send.
func update(p: Vector2) -> String:
	var d_enter := p.distance_to(ENTER_POINT)
	var d_exit := p.distance_to(EXIT_POINT)
	# rearm a held threshold once the player has left its radius
	if _hold_enter and d_enter >= RADIUS:
		_hold_enter = false
	if _hold_exit and d_exit >= RADIUS:
		_hold_exit = false
	if not in_ashmoor:
		if d_enter < RADIUS and not _hold_enter:
			in_ashmoor = true
			_hold_enter = true
			_hold_exit = true  # server drops us at the arrival monolith; hold exit until we walk off
			return "enter_era"
	else:
		if d_exit < RADIUS and not _hold_exit:
			in_ashmoor = false
			_hold_exit = true
			_hold_enter = true
			return "leave_era"
	return ""
