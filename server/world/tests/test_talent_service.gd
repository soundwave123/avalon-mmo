extends GutTest
# T-508: the world talent_service respec route. The master already owns the wipe (_reroll_talents);
# this asserts the world (a) recognizes the intent, (b) forwards it to the master, (c) re-sends
# authoritative talent state so the panel re-renders cleared, and (d) re-derives combat stats on
# success only (a wiped build changes the profile — mirrors the _spend_talent repush).

const TalentService = preload("res://scripts/talent_service.gd")


class FakeMaster:
	var calls: Array = []
	var responses: Dictionary = {}

	func call_master(name: String, params: Dictionary) -> Dictionary:
		calls.append({"name": name, "params": params})
		return responses.get(name, {})


class FakeRpc:
	extends RefCounted
	var replies: Array = []
	var repushes: Array = []
	var _master := FakeMaster.new()
	var _content_talents: Dictionary = {}
	var _reply: Callable

	func _init() -> void:
		_reply = func(peer_id, msg): replies.append({"peer_id": peer_id, "msg": msg})

	func _repush_combat_stats(peer_id: int, username: String) -> void:
		repushes.append({"peer_id": peer_id, "username": username})


func _svc(rpc) -> RefCounted:
	var svc = TalentService.new()
	svc.setup(rpc)
	return svc


func test_recognizes_the_reroll_intent() -> void:
	assert_true(TalentService.new().handles("reroll_talents"), "world routes the respec intent")


func test_reroll_forwards_to_master_resends_state_and_repushes_on_success() -> void:
	var rpc := FakeRpc.new()
	rpc._master.responses = {
		"reroll_talents": {"ok": true, "reason": ""},
		"get_talents":
		{"talents": {}, "points_available": 5, "points_spent": 0, "class": "warrior"},
	}
	await _svc(rpc).handle("reroll_talents", 7, {"username": "bob"}, {})

	assert_eq(rpc._master.calls[0]["name"], "reroll_talents", "the wipe is forwarded to the master")
	assert_eq(rpc._master.calls[0]["params"]["username"], "bob")
	# The client only renders server truth — a fresh talents reply follows the wipe.
	var kinds: Array = rpc.replies.map(func(r): return r["msg"]["type"])
	assert_true(kinds.has("talents"), "authoritative talent state is re-sent to the client")
	assert_eq(
		int(rpc.replies[-1]["msg"]["points_available"]), 5, "budget reflects the cleared build"
	)
	assert_eq(rpc.repushes.size(), 1, "a wiped build re-derives combat stats")
	assert_eq(rpc.repushes[0]["username"], "bob")


# T-520: the world routes set_gender — recognizes the intent, forwards it to the master with the
# username+gender, and acks server truth back to the client as set_gender_result. Gender has no
# combat consequence, so (unlike set_class) it must NOT repush combat stats.
func test_recognizes_and_routes_set_gender() -> void:
	assert_true(TalentService.new().handles("set_gender"), "world routes the gender intent")

	var rpc := FakeRpc.new()
	rpc._master.responses = {"set_gender": {"ok": true, "reason": "", "gender": "female"}}
	await _svc(rpc).handle("set_gender", 9, {"username": "bob"}, {"gender": "female"})

	assert_eq(rpc._master.calls[0]["name"], "set_gender", "forwarded to the master")
	assert_eq(rpc._master.calls[0]["params"]["username"], "bob")
	assert_eq(rpc._master.calls[0]["params"]["gender"], "female")
	assert_eq(rpc.replies[-1]["msg"]["type"], "set_gender_result", "client gets the ack")
	assert_true(bool(rpc.replies[-1]["msg"]["ok"]))
	assert_eq(str(rpc.replies[-1]["msg"]["gender"]), "female")
	assert_eq(rpc.repushes.size(), 0, "gender has no combat consequence — no stat re-derive")


func test_reroll_failure_still_resyncs_but_does_not_repush() -> void:
	var rpc := FakeRpc.new()
	rpc._master.responses = {
		"reroll_talents": {"ok": false, "reason": "unknown_character"},
		"get_talents": {"talents": {}, "points_available": 0, "points_spent": 0, "class": ""},
	}
	await _svc(rpc).handle("reroll_talents", 3, {"username": "ghost"}, {})

	var kinds: Array = rpc.replies.map(func(r): return r["msg"]["type"])
	assert_true(kinds.has("talents"), "client still gets an authoritative resync on a no-op")
	assert_eq(rpc.repushes.size(), 0, "no stat re-derive when nothing changed")
