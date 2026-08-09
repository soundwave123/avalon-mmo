# T-422c: the action-bar layout units — the PURE validation/ordering (BarLayoutOps) and the world
# intent service (BarLayoutService): a forged layout naming an unlearned ability is rejected and
# never persisted; a legal reorder round-trips and is persisted via master; the saved order applies
# to the kit at spawn. Identity + known-kit come from the server, never the packet.

extends GutTest

const _BLO = preload("res://scripts/bar_layout_ops.gd")
const _SVC = preload("res://scripts/bar_layout_service.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const TOK := "aaaaaaaa11111111aaaaaaaa11111111"  # gitleaks:allow


# A capturing stand-in for MasterClient — records every persist call so tests can assert the write
# happened (or, on a rejected forgery, did NOT).
class FakeMaster:
	extends RefCounted
	var calls: Array = []

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		return {"ok": true}


var _sent: Array = []


func before_each() -> void:
	PlayerSessions._reset_for_test()
	_sent = []


func _kit(ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		out.append({"id": id, "name": "Ability %d" % id})
	return out


# ---- BarLayoutOps.sanitize (the permutation gate) ----------------------------


func test_sanitize_accepts_a_legal_reorder() -> void:
	var clean := _BLO.sanitize([204, 1, 202, 201], [1, 201, 202, 204])
	assert_eq(clean, [204, 1, 202, 201], "a reorder of the known ids passes through verbatim")


func test_sanitize_rejects_an_unknown_ability() -> void:
	# 999 is not in the character's known kit — a forged "place an ability I never learned".
	assert_eq(
		_BLO.sanitize([1, 201, 999], [1, 201, 202]), [], "unknown id rejects the whole layout"
	)


func test_sanitize_rejects_a_duplicate() -> void:
	assert_eq(_BLO.sanitize([1, 201, 1], [1, 201, 202]), [], "a duplicated slot assignment rejects")


func test_sanitize_accepts_a_subset() -> void:
	# Fewer ids than known is legal (order_kit appends the rest) — still no unknown, no dup.
	assert_eq(_BLO.sanitize([202, 1], [1, 201, 202]), [202, 1], "a known subset is accepted")


func test_sanitize_coerces_float_ids() -> void:
	# JSON-parsed ids arrive as floats over the wire; sanitize normalizes to int.
	assert_eq(_BLO.sanitize([204.0, 1.0], [1, 204]), [204, 1], "float ids coerce to int")


# ---- BarLayoutOps.order_kit / ids --------------------------------------------


func test_order_kit_applies_the_saved_order() -> void:
	var ordered := _BLO.order_kit(_kit([1, 201, 202, 204]), [204, 202, 201, 1])
	assert_eq(_BLO.ids(ordered), [204, 202, 201, 1], "kit rows follow the saved layout order")


func test_order_kit_appends_a_newly_learned_ability() -> void:
	# The saved layout predates learning 204; it must still appear (appended in registry order).
	var ordered := _BLO.order_kit(_kit([1, 201, 202, 204]), [202, 1, 201])
	assert_eq(_BLO.ids(ordered), [202, 1, 201, 204], "an unmentioned known ability appends after")


func test_order_kit_empty_layout_is_a_noop() -> void:
	var ordered := _BLO.order_kit(_kit([1, 201, 202]), [])
	assert_eq(_BLO.ids(ordered), [1, 201, 202], "no saved layout leaves the default order")


# ---- BarLayoutService (the intent seam) --------------------------------------


func _svc(master) -> RefCounted:
	var s = _SVC.new()
	s.setup(master, func(pid: int, msg: Dictionary): _sent.append({"pid": pid, "msg": msg}))
	return s


func _reply_to(peer_id: int) -> Dictionary:
	for e in _sent:
		if int(e["pid"]) == peer_id:
			return e["msg"]
	return {}


func test_valid_reorder_round_trips_and_persists() -> void:
	PlayerSessions.add_player(1, TOK, "Alice", Vector3.ZERO)
	var master := FakeMaster.new()
	var s = _svc(master)
	s.set_known(1, [1, 201, 202, 204])
	s.handle("set_bar_layout", 1, {"layout": [204, 1, 202, 201]})
	var reply := _reply_to(1)
	assert_true(bool(reply.get("ok", false)), "a legal reorder is accepted")
	assert_eq(reply.get("layout", []), [204, 1, 202, 201], "the confirmed order echoes back")
	assert_eq(s.bar_layout_for(1), [204, 1, 202, 201], "the saved order updates for the kit send")
	assert_eq(master.calls.size(), 1, "the validated order is persisted exactly once")
	assert_eq(str(master.calls[0]["method"]), "save_bar_layout", "persisted via save_bar_layout")
	assert_eq(
		str(master.calls[0]["params"]["username"]), "Alice", "persist keys off the session name"
	)


func test_forged_unknown_ability_rejected_and_not_persisted() -> void:
	PlayerSessions.add_player(1, TOK, "Alice", Vector3.ZERO)
	var master := FakeMaster.new()
	var s = _svc(master)
	s.set_known(1, [1, 201, 202])
	# The client forges a layout containing 999 — an ability Alice never learned.
	s.handle("set_bar_layout", 1, {"layout": [1, 999, 201]})
	var reply := _reply_to(1)
	assert_false(
		bool(reply.get("ok", true)), "CRIT: a forged unowned-ability layout must be rejected"
	)
	assert_eq(str(reply.get("reason", "")), "invalid_layout", "rejection reason is invalid_layout")
	assert_eq(master.calls.size(), 0, "CRIT: a rejected layout must NEVER hit persistence")
	assert_eq(s.bar_layout_for(1), [], "the saved order is untouched by a rejected forgery")


func test_unknown_peer_is_dropped() -> void:
	var master := FakeMaster.new()
	var s = _svc(master)
	s.handle("set_bar_layout", 99, {"layout": [1, 2]})
	assert_eq(_sent.size(), 0, "a peer with no session gets no reply")
	assert_eq(master.calls.size(), 0, "and nothing is persisted")


func test_seed_supplies_the_spawn_order() -> void:
	var s = _svc(FakeMaster.new())
	s.seed(1, [204, 201, 1])
	assert_eq(s.bar_layout_for(1), [204, 201, 1], "the master combat payload seeds the saved order")
