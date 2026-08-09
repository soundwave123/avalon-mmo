extends GutTest
# T-334: LFG-lite board — pure lfg_logic ops + the instance_service intent seam (flag/unflag/list,
# server-derived role, clear-on-group-up prune, clear-on-disconnect). No scene tree, no sessions.

const _LFG = preload("res://scripts/lfg_logic.gd")
const _ISVC = preload("res://scripts/instance_service.gd")

# ---- pure lfg_logic ----


func test_role_for_class_is_the_trinity_map() -> void:
	assert_eq(_LFG.role_for_class("warrior"), "tank")
	assert_eq(_LFG.role_for_class("priest"), "heal")
	assert_eq(_LFG.role_for_class("mage"), "dps")
	assert_eq(_LFG.role_for_class("gnome_tinker"), "dps", "unknown class floors to dps")


func test_flag_adds_and_reflag_refreshes() -> void:
	var s := _LFG.new_store()
	_LFG.flag(s, 7, 12, "tank")
	assert_true(_LFG.is_flagged(s, 7))
	assert_eq(_LFG.count(s), 1)
	_LFG.flag(s, 7, 13, "tank")  # re-flag = refresh, not duplicate
	assert_eq(_LFG.count(s), 1)
	assert_eq(int(_LFG.board(s)[0]["level"]), 13, "re-flag refreshed the level")


func test_unflag_removes_and_is_idempotent() -> void:
	var s := _LFG.new_store()
	_LFG.flag(s, 7, 12, "dps")
	_LFG.unflag(s, 7)
	assert_false(_LFG.is_flagged(s, 7))
	_LFG.unflag(s, 7)  # second unflag is a no-op
	assert_eq(_LFG.count(s), 0)


func test_board_is_sorted_by_peer_and_carries_level_role() -> void:
	var s := _LFG.new_store()
	_LFG.flag(s, 9, 15, "heal")
	_LFG.flag(s, 3, 12, "tank")
	var b := _LFG.board(s)
	assert_eq(b.size(), 2)
	assert_eq(int(b[0]["peer"]), 3, "board sorted by peer id (signup order)")
	assert_eq(str(b[0]["role"]), "tank")
	assert_eq(int(b[1]["level"]), 15)


func test_prune_partied_clears_grouped_peers() -> void:
	var s := _LFG.new_store()
	_LFG.flag(s, 1, 12, "tank")
	_LFG.flag(s, 2, 13, "dps")
	var dropped := _LFG.prune_partied(s, {2: 41})  # peer 2 joined party 41
	assert_eq(dropped, [2], "the grouped peer is pruned (clear-on-group-up)")
	assert_true(_LFG.is_flagged(s, 1), "the still-solo peer stays listed")
	assert_false(_LFG.is_flagged(s, 2))


# ---- the instance_service intent seam ----


# A service wired to hermetic stores + no-op callables; replies captured into `sink`.
func _svc(party_of: Dictionary, char_class: Dictionary, sink: Array):
	var svc = _ISVC.new()
	var nop2 := func(_a, _b): pass
	var nop1 := func(_a): pass
	svc.setup({}, party_of, nop2, nop2, nop1)
	svc.setup_lfg(char_class, func(peer, msg): sink.append({"peer": peer, "msg": msg}))
	return svc


func test_service_handles_the_lfg_intents() -> void:
	var svc = _svc({}, {}, [])
	assert_true(svc.handles("lfg_flag"))
	assert_true(svc.handles("lfg_unflag"))
	assert_true(svc.handles("lfg_list"))
	assert_false(svc.handles("lfg_teleport_me_to_the_boss"))


func test_flag_derives_role_from_session_class_not_the_wire() -> void:
	var sink: Array = []
	var svc = _svc({}, {5: "mage"}, sink)
	# The wire claims tank; the session says mage. The server must list dps.
	svc.handle("lfg_flag", 5, {"level": 14, "role": "tank"})
	assert_eq(sink.size(), 1)
	var msg: Dictionary = sink[0]["msg"]
	assert_eq(str(msg["type"]), "lfg_board")
	assert_true(bool(msg["ok"]))
	assert_eq(msg["board"].size(), 1)
	assert_eq(str(msg["board"][0]["role"]), "dps", "role comes from the session class")
	assert_eq(int(msg["board"][0]["level"]), 14)


func test_flag_rejected_while_in_a_party() -> void:
	var sink: Array = []
	var svc = _svc({5: 41}, {5: "warrior"}, sink)
	svc.handle("lfg_flag", 5, {"level": 12})
	var msg: Dictionary = sink[0]["msg"]
	assert_false(bool(msg["ok"]))
	assert_eq(str(msg["reason"]), "in_party")
	assert_eq(msg["board"].size(), 0, "a partied player never lands on the board")


func test_group_up_prunes_on_the_next_board_op() -> void:
	var sink: Array = []
	var party_of := {}
	var svc = _svc(party_of, {2: "priest", 3: "warrior"}, sink)
	svc.handle("lfg_flag", 2, {"level": 13})
	party_of[2] = 41  # peer 2 groups up (T-280 accept) — no LFG hook fires
	svc.handle("lfg_list", 3, {})
	var msg: Dictionary = sink[1]["msg"]
	assert_eq(msg["board"].size(), 0, "the grouped peer was pruned at the next read")


func test_unflag_and_disconnect_clear_the_board() -> void:
	var sink: Array = []
	var svc = _svc({}, {2: "priest", 3: "warrior"}, sink)
	svc.handle("lfg_flag", 2, {"level": 13})
	svc.handle("lfg_flag", 3, {"level": 12})
	svc.handle("lfg_unflag", 2, {})
	assert_eq(svc.lfg_board().size(), 1, "unflag removed peer 2")
	svc.on_peer_gone(3)  # disconnect path (main._release_local_peer_state)
	assert_eq(svc.lfg_board().size(), 0, "disconnect cleared the last entry")
