extends GutTest

# T-431: the world-side authority gate. The client names only a destination; source, topology,
# price, coordinates, region, and height all come from server data/state.

const FlightService = preload("res://scripts/flight_service.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const BroadcastBuilder = preload("res://scripts/broadcast_builder.gd")
const TerrainField = preload("res://scripts/terrain_field.gd")

const TOKEN := "cccccccccccccccccccccccccccccccc"  # gitleaks:allow


class FakeMaster:
	var calls: Array = []
	var responses: Dictionary = {}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params.duplicate(true)})
		return responses.get(str(params.get("action", "")), {"ok": true, "known_nodes": []})


var _master: FakeMaster
var _replies: Array
var _svc


func before_each() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(7, TOKEN, "traveller", Vector3(0.0, 0.0, 0.0))
	_master = FakeMaster.new()
	_replies = []
	_svc = FlightService.new()
	assert_eq(
		_svc.setup(
			_master,
			func(pid, msg): _replies.append([pid, msg]),
			"res://data/travel/flight_nodes.json"
		),
		""
	)


func after_each() -> void:
	PlayerSessions._reset_for_test()


func test_talking_at_roost_discovers_the_server_mapped_node() -> void:
	await _svc.discover(7, "traveller", "npc_village_flightmaster")
	assert_eq(_master.calls.size(), 1)
	assert_eq(_master.calls[0]["method"], "flight_op")
	assert_eq(_master.calls[0]["params"]["node"], "village")


func test_list_only_returns_known_direct_destinations_with_server_prices() -> void:
	_master.responses["list"] = {
		"ok": true, "known_nodes": ["village", "highkeep", "ashmoor"], "coins": 100
	}
	await _svc.handle(7, "traveller", "npc_village_flightmaster", {"action": "list"})
	var ack: Dictionary = _replies[-1][1]
	assert_true(ack["ok"])
	assert_eq((ack["destinations"] as Array).size(), 1, "village has one authored direct hop")
	assert_eq(str(ack["destinations"][0]["id"]), "highkeep")
	assert_eq(int(ack["destinations"][0]["cost"]), 25, "price comes from flight_nodes.json")


func test_fly_ignores_forged_cost_and_reseats_in_destination_region() -> void:
	_master.responses["fly"] = {"ok": true, "coins": 75}
	await _svc.handle(
		7,
		"traveller",
		"npc_hk_flightmaster",
		{"action": "fly", "dest": "ashmoor", "cost": 0, "x": 0, "region_id": "era1"}
	)
	var call: Dictionary = _master.calls[-1]
	assert_eq(int(call["params"]["cost"]), 60, "forged wire cost is ignored; graph price wins")
	var pos: Vector3 = PlayerSessions.get_player(7)["pos"]
	assert_true(pos.is_equal_approx(Vector3(-408.0, -4.0, TerrainField.new().height(-408.0, -4.0))))
	assert_eq(
		BroadcastBuilder.region_of(pos.x, pos.y), 2, "hop immediately re-buckets into Ashmoor"
	)
	assert_eq(str(_replies[-1][1]["dest"]), "ashmoor")


func test_forged_unknown_or_unconnected_destination_never_reaches_master_or_moves() -> void:
	var before: Vector3 = PlayerSessions.get_player(7)["pos"]
	await _svc.handle(
		7, "traveller", "npc_village_flightmaster", {"action": "fly", "dest": "bogus"}
	)
	assert_eq(str(_replies[-1][1]["reason"]), "unknown_roost")
	await _svc.handle(
		7, "traveller", "npc_village_flightmaster", {"action": "fly", "dest": "ashmoor"}
	)
	assert_eq(str(_replies[-1][1]["reason"]), "route_unavailable")
	assert_eq(_master.calls.size(), 0, "bad topology is rejected before the master round-trip")
	assert_eq(PlayerSessions.get_player(7)["pos"], before)


func test_underfunded_master_verdict_never_repositions() -> void:
	_master.responses["fly"] = {"error": "insufficient_coins"}
	var before: Vector3 = PlayerSessions.get_player(7)["pos"]
	await _svc.handle(7, "traveller", "npc_hk_flightmaster", {"action": "fly", "dest": "ashmoor"})
	assert_eq(PlayerSessions.get_player(7)["pos"], before, "failed debit means no teleport")
	assert_eq(str(_replies[-1][1]["reason"]), "insufficient_coins")
