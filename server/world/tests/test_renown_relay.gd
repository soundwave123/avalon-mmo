extends GutTest

# T-678: the world-side renown read relay (rides the T-367 achievement_service object). The world
# is a thin trust boundary: identity comes from the SESSION player dict (never the wire), the only
# renown message is a read, and the reply is a verbatim mirror of the master's renown_op rows.
# FakeMaster pattern mirrors test_flight_service.

const AchievementService = preload("res://scripts/achievement_service.gd")


class FakeMaster:
	var calls: Array = []
	var response: Dictionary = {}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params.duplicate(true)})
		return response


var _master: FakeMaster
var _replies: Array
var _svc


func before_each() -> void:
	_master = FakeMaster.new()
	_replies = []
	_svc = AchievementService.new()
	_svc.setup(_master, func(pid, msg): _replies.append([pid, msg]))


func test_handles_both_read_intents_and_nothing_else() -> void:
	assert_true(_svc.handles("achievement_list"))
	assert_true(_svc.handles("renown_list"), "the renown read rides the same relay")
	assert_false(_svc.handles("renown_grant"), "no grant intent exists on the world boundary")
	assert_false(_svc.handles("turn_in"))


func test_renown_read_asks_master_with_session_identity() -> void:
	_master.response = {"renown": []}
	await _svc.handle_renown_read(7, {"username": "traveller", "peer_id": 7})
	assert_eq(_master.calls.size(), 1)
	assert_eq(str(_master.calls[0]["method"]), "renown_op")
	assert_eq(str(_master.calls[0]["params"]["username"]), "traveller", "session name, not wire")
	assert_eq(str(_master.calls[0]["params"]["action"]), "list", "the only action is a read")


func test_renown_reply_mirrors_master_rows_to_the_asking_peer() -> void:
	var rows := [
		{
			"hub": "highkeep",
			"name": "Highkeep",
			"points": 150,
			"rank": 2,
			"rank_name": "Newcomer",
			"next_points": 400,
		}
	]
	_master.response = {"renown": rows}
	await _svc.handle_renown_read(7, {"username": "traveller"})
	assert_eq(_replies.size(), 1)
	assert_eq(int(_replies[0][0]), 7, "reply goes to the asking peer")
	var msg: Dictionary = _replies[0][1]
	assert_eq(str(msg["type"]), "renown_list")
	assert_eq(msg["renown"], rows, "rows pass through verbatim — the world adds nothing")


func test_renown_error_reply_degrades_to_empty_rows() -> void:
	_master.response = {"error": "unknown_character"}
	await _svc.handle_renown_read(7, {"username": "ghost"})
	assert_eq(_replies[0][1]["renown"], [], "an error reply renders as an empty track, not a crash")
