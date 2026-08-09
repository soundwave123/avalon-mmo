extends RefCounted
# T-705: the world's first-session-funnel emitter. world_rpc.gd sits at the gdlint file cap, so the
# event vocabulary (which beat, which failure reason, what rides the payload) lives HERE and every
# call site over there stays one line — the same carve the craft/mail/loot seams already use.
#
# Every emit is fire-and-forget onto the T-186 five-second batch: nothing here awaits, nothing here
# reads or writes gameplay state, and a dead telemetry pump degrades to silence. Each signal is
# recorded ONCE PER SESSION (rejections: once per reason) because the funnel only ever reads the
# first of each — so a player looting 200 wolves adds one row, not two hundred.

const BOOT_MS_MAX := 3_600_000  # an hour-long boot phase is a suspended process, not a launch

var _tel: Callable = Callable()  # main._tel(event_type, peer_id, payload, once_key)


# main injects the telemetry pump (via world_rpc). Without it every call below is a no-op, which is
# the correct degraded behavior: measurement must never be load-bearing for gameplay.
func setup(tel: Callable) -> void:
	_tel = tel


# The client's own launch → login-submit → world-interactive stopwatch — the pre-spawn dead air the
# funnel could not see (it anchored on spawn, but a refund clock starts at process launch). The
# numbers are CLAMPED here because they originate on the client: a forged value can only ever be a
# number in range, and nothing about it grants, unlocks, or changes anything.
func boot_timing(peer_id: int, data: Dictionary) -> void:
	_emit(
		"client_boot_timing",
		peer_id,
		{
			"launch_to_login_ms": _ms(data.get("launch_to_login_ms", 0)),
			"login_to_interactive_ms": _ms(data.get("login_to_interactive_ms", 0)),
		}
	)


func quest_accept(peer_id: int, quest_id: String) -> void:
	_emit("quest_accept", peer_id, {"quest_id": quest_id})


func quest_turn_in(peer_id: int, quest_id: String) -> void:
	_emit("quest_turn_in", peer_id, {"quest_id": quest_id})


func loot(peer_id: int, items: Array) -> void:
	_emit("loot", peer_id, {"items": items.size()})


# A refusal the player actually SAW. `intent` is what they were trying to do and `reason` is the
# server's own rejection code — together they name the quit-risk moment (portal #85 is exactly this
# shape) without recording anything about the player beyond the pseudonymous character.
func rejected(peer_id: int, intent: String, reason: String) -> void:
	if reason == "":
		return
	_emit("intent_rejected", peer_id, {"intent": intent, "reason": reason}, "reject:" + reason)


# The bag ops: a first equip is a funnel BEAT, a refusal (bag_full / insufficient_count) is a
# failure reason. Both come off the same master reply, so one call site covers the pair.
func inventory(peer_id: int, method: String, result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		if method == "equip":
			_emit("equip", peer_id, {})
		return
	rejected(peer_id, method, str(result.get("reason", result.get("error", ""))))


# The service-hub ops (trainer / vendor / bank / auction). Only refusals matter to the funnel —
# `insufficient_coins` at a trainer is precisely the "reward you cannot claim" moment T-715 closed.
func service(peer_id: int, service_tag: String, action: String, ack: Dictionary) -> void:
	if bool(ack.get("ok", false)):
		return
	rejected(peer_id, "%s:%s" % [service_tag, action], str(ack.get("reason", "")))


func _emit(event_type: String, peer_id: int, payload: Dictionary, key: String = "") -> void:
	if _tel.is_valid():
		_tel.call(event_type, peer_id, payload, event_type if key == "" else key)


func _ms(raw) -> int:
	return clampi(int(raw), 0, BOOT_MS_MAX)
