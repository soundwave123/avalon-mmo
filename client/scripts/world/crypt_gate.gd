# T-330: the churchyard-stair threshold trigger for the Hollowed Crypt (the T-331
# handoff — "the stair-threshold trigger is yours"). A pure, unit-testable proximity
# state machine (npc_wander.gd / critter_wander.gd tick style: no OS time, no engine
# access, caller injects the player's ground position). It watches TWO thresholds:
#   - "enter_instance": player (open world) steps onto the churchyard crypt porch
#   - "leave_instance": player (inside the crypt) climbs back up the vestibule stair
# The server (instance_service.gd) owns the teleport + spawn scope; this only fires
# the intent. Debounce: after a fire the matching point is HELD until the player
# walks back out of its radius, so standing on a threshold fires exactly once. The
# server drops the player far from the fired threshold on both transitions.
extends RefCounted

# WORLD ground coords (server x, y). ENTER = the churchyard porch (placed ~(14,-12.5));
# EXIT = the crypt vestibule stair foot in the distant offset region.
const ENTER_POINT := Vector2(14.0, -12.5)
const EXIT_POINT := Vector2(420.0, 2.2)
const RADIUS := 2.2

var in_crypt: bool = false
var _hold_enter: bool = false  # true while parked inside the enter radius (blocks re-fire)
var _hold_exit: bool = false


# `p` = player ground position (Godot global_position.x, .z == server x, y).
# Returns "enter_instance", "leave_instance", or "" — the server intent to send.
func update(p: Vector2) -> String:
	var d_enter := p.distance_to(ENTER_POINT)
	var d_exit := p.distance_to(EXIT_POINT)
	# rearm a held threshold once the player has left its radius
	if _hold_enter and d_enter >= RADIUS:
		_hold_enter = false
	if _hold_exit and d_exit >= RADIUS:
		_hold_exit = false
	if not in_crypt:
		if d_enter < RADIUS and not _hold_enter:
			in_crypt = true
			_hold_enter = true
			_hold_exit = true  # server drops us at the vestibule; hold exit until we walk off it
			return "enter_instance"
	else:
		if d_exit < RADIUS and not _hold_exit:
			in_crypt = false
			_hold_exit = true
			_hold_enter = true
			return "leave_instance"
	return ""
