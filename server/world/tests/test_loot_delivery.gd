extends GutTest

# T-644 (portal #89): kill-loot delivery through world_rpc.on_mob_loot -> loot_delivery.gd. Covers
# the world-side half of the fix — candidate ordering (killer first, then party fallback via
# mentorship_service.party_peers_of) and the client-visible hold notice on total failure. The
# master-side grant/hold mechanism itself is covered by server/master/tests/test_loot_ops.gd.

const WorldRpc = preload("res://scripts/world_rpc.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const MentorshipService = preload("res://scripts/mentorship_service.gd")
const PartyLogic = preload("res://scripts/party_logic.gd")

const TOKEN_A := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0"  # gitleaks:allow
const TOKEN_B := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb1"  # gitleaks:allow


class FakeMaster:
	var calls: Array = []
	var response: Dictionary = {"ok": true, "credited": []}

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		return response


var _fm: FakeMaster
var _rpc
var _replied: Array = []


func _make() -> void:
	_fm = FakeMaster.new()
	_replied = []
	_rpc = WorldRpc.new()
	var err: String = _rpc.setup(_fm, func(_pid, d): _replied.append(d))
	assert_eq(err, "", "content loads at setup")


func _last_call(method: String) -> Dictionary:
	for c in _fm.calls:
		if c["method"] == method:
			return c
	return {}


func test_solo_killer_is_the_only_candidate() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "alice", Vector3.ZERO)
	_rpc.on_mob_loot(10, [{"item": "itm_wolf_pelt", "count": 1}])
	await get_tree().process_frame
	var call := _last_call("grant_loot")
	assert_false(call.is_empty(), "one grant_loot round-trip")
	assert_eq(call["params"]["usernames"], ["alice"], "solo killer is the only candidate")


func test_partied_killer_offers_fallback_to_party_members() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "alice", Vector3.ZERO)
	PlayerSessions.add_player(20, TOKEN_B, "bob", Vector3.ZERO)
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var mentor := MentorshipService.new()
	mentor.setup(
		store, {10: 5, 20: 5}, func(_p, _c, _s, _t, _l, _pr = false): pass, func(_p, _m): pass
	)
	_rpc._set_mentorship(mentor)
	_rpc.on_mob_loot(10, [{"item": "itm_wolf_pelt", "count": 1}])
	await get_tree().process_frame
	var call := _last_call("grant_loot")
	assert_eq(
		call["params"]["usernames"], ["alice", "bob"], "killer first, then the party fallback"
	)


func test_no_master_call_for_empty_items() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "alice", Vector3.ZERO)
	_rpc.on_mob_loot(10, [])
	await get_tree().process_frame
	assert_true(_fm.calls.is_empty(), "no round-trip for an empty drop")


func test_total_failure_sends_a_visible_hold_notice_never_silent() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "alice", Vector3.ZERO)
	_fm.response = {"ok": false, "reason": "bag_full", "held": true}
	_rpc.on_mob_loot(10, [{"item_id": "itm_wolf_pelt", "count": 2}])
	await get_tree().process_frame
	var notices := _replied.filter(func(r): return r.get("type", "") == "loot_notice")
	assert_eq(
		notices.size(), 1, "a bag-full grant failure must surface — T-575 visible-failure rule"
	)
	assert_eq(str(notices[0]["reason"]), "bag_full_held")
	assert_eq(str(notices[0]["items"][0]["item_id"]), "itm_wolf_pelt")
	assert_eq(int(notices[0]["items"][0]["count"]), 2)


func test_success_pushes_quest_delta_to_whoever_was_actually_granted() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "alice", Vector3.ZERO)
	PlayerSessions.add_player(20, TOKEN_B, "bob", Vector3.ZERO)
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var mentor := MentorshipService.new()
	mentor.setup(
		store, {10: 5, 20: 5}, func(_p, _c, _s, _t, _l, _pr = false): pass, func(_p, _m): pass
	)
	_rpc._set_mentorship(mentor)
	# The killer (alice) was full; the master reports the fallback (bob) as the actual recipient.
	_fm.response = {"ok": true, "credited": ["q001"], "granted_to": "bob"}
	_rpc.on_mob_loot(10, [{"item": "itm_wolf_pelt", "count": 1}])
	for _frame in 4:
		await get_tree().process_frame
	var deltas := _replied.filter(func(r): return r.get("type", "") == "quest_delta")
	assert_eq(deltas.size(), 1, "one quest_delta pushed")
	# quest_delta is pushed to bob's peer (20), not the killer's (10) — the actual recipient.
	var qc := _last_call("quest_entry")
	assert_eq(str(qc["params"]["username"]), "bob", "the delta is fetched for the actual recipient")
