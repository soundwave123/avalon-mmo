class_name InteriorGate
extends RefCounted

# T-187: the live "is the player indoors right now" tracker that main.gd polls (throttled) each
# frame and feeds into rain suppression (WorldView.set_rain_suppressed) + ambience muffling
# (AudioManager.set_indoor_muffle). Wraps InteriorZones.resolve_indoors() — the pure hysteresis
# math — with a little state so callers get simple booleans/deltas instead of re-deriving the
# enter/exit dance themselves.
#
# Deliberately does NOT own the rain on/off truth: WorldView already tracks what the outdoor
# weather system asked for (_rain_wanted) and layers suppression on top via
# set_rain_suppressed(), so there's exactly one place ("does it rain outside") a weather system
# needs to write to, and this gate only ever says "and are we indoors right now".

const InteriorZones = preload("res://scripts/world/interior_zones.gd")

var _indoors := false
var _volume_id := ""


# Advances indoor state from a new player position; returns true if the indoor/outdoor state (or
# which building) just changed — callers can skip re-applying rain/ambience when nothing crossed
# a threshold this tick.
func update_position(point: Vector3, volumes: Array) -> bool:
	var res := InteriorZones.resolve_indoors(point, volumes, _indoors, _volume_id)
	var changed: bool = bool(res["indoors"]) != _indoors or str(res["id"]) != _volume_id
	_indoors = bool(res["indoors"])
	_volume_id = str(res["id"])
	return changed


func is_indoors() -> bool:
	return _indoors


func volume_id() -> String:
	return _volume_id
