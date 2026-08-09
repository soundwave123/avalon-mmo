extends "res://addons/gut/test.gd"

# T-597 (portal report #47): the "choose your gender" modal spontaneously reopened mid-session on
# an already-created character. Root cause: _refresh_kit_after_training (the T-208 post-training
# kit resend) called _send_class_kit WITHOUT a gender argument, silently defaulting to "" — and
# the same bare-Callable hole existed on the mentor-sync kit resend (T-452, fires on a party
# class-change cascade). Both now read gender from main's persisted-value cache instead of a
# caller-supplied argument, so no resend can ever blank it out again. Mirrors the
# test_build_gate_handshake.gd harness style: a _send_to_peer-capturing subclass of main.gd,
# instantiated WITHOUT _ready() (no ENet/master), with _fetch_combat stubbed to skip the real
# master round trip.

const PlayerSessions = preload("res://scripts/player_sessions.gd")
const AbilityRegistry = preload("res://scripts/combat/ability_registry.gd")

const PEER := 55
const TOKEN := "dddddddddddddddddddddddddddddd04"  # gitleaks:allow


class _HarnessMain:
	extends "res://scripts/main.gd"
	var sent: Array = []
	var combat_response: Dictionary = {}

	func _send_to_peer(peer_id: int, data: Dictionary) -> void:
		sent.append({"peer_id": peer_id, "data": data})

	func _fetch_combat(_username: String) -> Dictionary:
		return combat_response

	func class_kit_msgs() -> Array:
		var out: Array = []
		for s in sent:
			if s["data"].get("type", "") == "class_kit":
				out.append(s["data"])
		return out


func _make() -> _HarnessMain:
	var m := _HarnessMain.new()
	m._ability_registry = AbilityRegistry.new()
	m._ability_registry.load_from_dir("res://data/abilities")
	return m


func before_each() -> void:
	PlayerSessions._reset_for_test()


# ---- (a) the confirmed T-597 lead: the training-refresh kit resend ----------------------------


func test_kit_refresh_carries_persisted_gender_not_blank() -> void:
	PlayerSessions.add_player(PEER, TOKEN, "hero", Vector3.ZERO)
	var m := _make()
	m._char_class[PEER] = "warrior"
	m._char_gender[PEER] = "female"  # seeded exactly as login does
	# The master combat re-fetch this refresh triggers still answers with the real gender — the bug
	# was that _send_class_kit discarded it, not that the fetch itself was wrong.
	m.combat_response = {"class_locked": true, "gender": "female"}

	await m._refresh_kit_after_training(PEER)

	var kits := m.class_kit_msgs()
	assert_eq(kits.size(), 1, "exactly one class_kit resend")
	assert_eq(kits[0]["gender"], "female", 'kit refresh must carry the persisted gender, not ""')
	m.free()


func test_kit_refresh_before_after_gender_count_never_regresses() -> void:
	# Counts must go UP, never sideways: two consecutive refreshes on a gendered character must
	# BOTH carry the real value — a one-shot fix that only patches the first resend isn't enough.
	PlayerSessions.add_player(PEER, TOKEN, "hero", Vector3.ZERO)
	var m := _make()
	m._char_class[PEER] = "mage"
	m._char_gender[PEER] = "male"
	m.combat_response = {"class_locked": true, "gender": "male"}

	await m._refresh_kit_after_training(PEER)
	await m._refresh_kit_after_training(PEER)

	var gendered_sends := 0
	for k in m.class_kit_msgs():
		if k["gender"] == "male":
			gendered_sends += 1
	assert_true(gendered_sends >= 2, "every refresh in the run carries the persisted gender")
	m.free()


# ---- the other broken call site: mentor-sync's bare Callable(self, "_send_class_kit") ----------


func test_mentor_triggered_kit_send_carries_persisted_gender() -> void:
	# mentorship_service.gd calls the bound Callable as _send_kit.call(peer, char_class) — two
	# positional args only. Before the fix, _send_class_kit's 4th (gender) param defaulted to "".
	# Now gender isn't a parameter at all — the function reads main's cache directly, so this
	# 2-arg call site is safe by construction.
	PlayerSessions.add_player(PEER, TOKEN, "hero", Vector3.ZERO)
	var m := _make()
	m._char_gender[PEER] = "female"

	m._send_class_kit(PEER, "priest")  # exactly how the mentor Callable invokes it

	var kits := m.class_kit_msgs()
	assert_eq(kits.size(), 1)
	assert_eq(kits[0]["gender"], "female", "the mentor-triggered resend must not blank the gender")
	m.free()


# ---- baseline: a genuinely ungendered (mid-creation) character is unaffected -------------------


func test_ungendered_character_still_sends_blank_gender() -> void:
	# The fix must not paper over a REAL "" — a brand-new character hasn't chosen yet, and the
	# client's gender panel needs that "" to know to show itself.
	PlayerSessions.add_player(PEER, TOKEN, "newbie", Vector3.ZERO)
	var m := _make()
	m.combat_response = {"class_locked": false, "gender": ""}

	await m._refresh_kit_after_training(PEER)

	var kits := m.class_kit_msgs()
	assert_eq(kits[0]["gender"], "", "a truly ungendered character still reports blank")
	m.free()
