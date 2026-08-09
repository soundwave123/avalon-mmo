class_name MountService
extends RefCounted

# T-431: server-owned movement mode. The client sends only {action:"toggle"}; learned mount,
# mounted state, speed caps and visual all come from the master-seeded profile and this store.
# Cosmetic skin selects only `visual`; both speed functions ignore it by construction.

const _SC := preload("res://scripts/server_config.gd")

var _profiles: Dictionary = {}  # peer -> {learned,mount_id,skin}
var _mounted: Dictionary = {}  # peer -> bool
var _set_session_state: Callable = Callable()
var _reply: Callable = Callable()


func setup(set_session_state: Callable, reply: Callable) -> void:
	_set_session_state = set_session_state
	_reply = reply


func seed(peer_id: int, profile: Dictionary) -> void:
	_profiles[peer_id] = {
		"learned": bool(profile.get("learned", false)),
		"mount_id": str(profile.get("mount_id", "")),
		"skin": str(profile.get("skin", "")),
	}
	_mounted[peer_id] = false
	_publish(peer_id, false)


func handles(msg_type: String) -> bool:
	return msg_type == "mount_intent"


func handle(peer_id: int, data: Dictionary, combat_state: int) -> void:
	if str(data.get("action", "")) != "toggle":
		_reject(peer_id, "bad_action")
		return
	var profile: Dictionary = _profiles.get(peer_id, {})
	if not bool(profile.get("learned", false)) or str(profile.get("mount_id", "")) == "":
		_reject(peer_id, "mount_not_learned")
		return
	if not is_mounted(peer_id) and combat_state != 0:  # CombatStateEnum.IDLE
		_reject(peer_id, "in_combat")
		return
	var next := not is_mounted(peer_id)
	_mounted[peer_id] = next
	_publish(peer_id, next)
	(
		_reply
		. call(
			peer_id,
			{
				"type": "mount_state",
				"ok": true,
				"mounted": next,
				"visual": visual_for(peer_id) if next else "",
			}
		)
	)


func dismount(peer_id: int, reason: String) -> bool:
	if not is_mounted(peer_id):
		return false
	_mounted[peer_id] = false
	_publish(peer_id, false)
	_reply.call(
		peer_id,
		{"type": "mount_state", "ok": true, "mounted": false, "visual": "", "reason": reason}
	)
	return true


func is_mounted(peer_id: int) -> bool:
	return bool(_mounted.get(peer_id, false))


func speed_cap(peer_id: int) -> float:
	return _SC.MAX_SPEED_MOUNTED_PER_TICK if is_mounted(peer_id) else _SC.MAX_SPEED_PER_TICK


func units_per_second(peer_id: int) -> float:
	return _SC.MOVE_UNITS_MOUNTED_PER_SECOND if is_mounted(peer_id) else _SC.MOVE_UNITS_PER_SECOND


# The one intake seam that selects the movement tier. Keeping the cap lookup and collision call
# together prevents callers from raising per-message speed without raising the matching 1s budget.
func resolve_move(
	collision, current: Vector2, delta: Vector2, peer_id: int, now_tick: int, limiter
):
	return collision.resolve(
		current, delta, peer_id, now_tick, limiter, speed_cap(peer_id), units_per_second(peer_id)
	)


func visual_for(peer_id: int) -> String:
	var profile: Dictionary = _profiles.get(peer_id, {})
	var skin := str(profile.get("skin", ""))
	return skin if skin != "" else str(profile.get("mount_id", ""))


# T-658: flip a live peer's cached profile to learned the instant a trainer purchase clears, so
# the very next mount keypress this session works — without it the player would need to relog for
# the login-time seed() to pick up the master's now-updated learned_mount. No-op for an unseeded/
# already-disconnected peer (nothing to unblock).
func mark_learned(peer_id: int) -> void:
	if _profiles.has(peer_id):
		_profiles[peer_id]["learned"] = true


func forget(peer_id: int) -> void:
	_profiles.erase(peer_id)
	_mounted.erase(peer_id)


func _publish(peer_id: int, mounted: bool) -> void:
	if _set_session_state.is_valid():
		_set_session_state.call(peer_id, mounted, visual_for(peer_id) if mounted else "")


func _reject(peer_id: int, reason: String) -> void:
	_reply.call(peer_id, {"type": "mount_state", "ok": false, "mounted": false, "reason": reason})
