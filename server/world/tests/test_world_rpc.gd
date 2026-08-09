extends "res://addons/gut/test.gd"
# TD-002: WorldRpc coordinator — content load + quest/inventory routing + kill-credit. Uses a fake
# master (a coroutine, so handle()'s await resolves like the real call_master) + a capture Callable.

const WorldRpc = preload("res://scripts/world_rpc.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const MentorshipService = preload("res://scripts/mentorship_service.gd")
const PartyLogic = preload("res://scripts/party_logic.gd")

const TOKEN := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0"  # gitleaks:allow


class FakeMaster:
	var calls: Array = []
	var responses: Dictionary = {}  # method -> Dictionary; falls back to the generic ok response

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		await Engine.get_main_loop().process_frame
		if responses.has(method):
			return responses[method]
		return {"ok": true, "slots": [], "credited": ["q001"], "reason": ""}


var _fm: FakeMaster = null
var _rpc = null
var _replied: Array = []
var _applied: Array = []  # T-061: (peer_id, stat_vec) captured from the level-up refresh callback


func _make() -> void:
	_fm = FakeMaster.new()
	_replied = []
	_applied = []
	_rpc = WorldRpc.new()
	var err: String = _rpc.setup(
		_fm,
		func(_pid, d): _replied.append(d),
		"res://data",
		func(pid, cls, stat_vec, talents = {}, level = 1, preserve = false):
			(
				_applied
				. append(
					{
						"pid": pid,
						"class": cls,
						"stats": stat_vec,
						"talents": talents,
						"level": level,
						"preserve": preserve,
					}
				)
			)
	)
	assert_eq(err, "", "content loads at setup")


func test_setup_loads_content() -> void:
	_make()
	assert_true(_rpc.content_ops.content_summary().contains("quests"), "content summary populated")


# T-705: capture what the funnel would ship, exactly as main._tel would be called.
func _watch_funnel() -> Array:
	var seen: Array = []
	_rpc._set_telemetry(
		func(event_type: String, pid: int, payload: Dictionary, _key: String) -> void:
			seen.append({"type": event_type, "pid": pid, "payload": payload})
	)
	return seen


func _funnel_types(seen: Array) -> Array:
	return seen.map(func(e): return str(e["type"]))


# T-705: accepting a quest is the funnel's "on quest" beat; a refused accept is a failure reason.
func test_accepting_a_quest_emits_the_funnel_beat_and_a_refusal_emits_its_reason() -> void:
	_make()
	var seen := _watch_funnel()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(3.0, 3.0, 0.0))  # by q001's giver
	_fm.responses["accept_quest"] = {"ok": true}
	await _rpc.handle("accept_quest", 10, {"quest_id": "q001"})
	assert_true(_funnel_types(seen).has("quest_accept"), "the on-quest beat is measured")
	assert_eq(str(seen[0]["payload"]["quest_id"]), "q001")
	# Standing far from the giver is a server refusal — the quit-risk signal T-705 wants.
	seen.clear()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(400.0, 400.0, 0.0))
	await _rpc.handle("accept_quest", 10, {"quest_id": "q001"})
	assert_eq(_funnel_types(seen), ["intent_rejected"])
	assert_eq(str(seen[0]["payload"]["reason"]), "too_far")
	assert_eq(str(seen[0]["payload"]["intent"]), "accept_quest")


# T-705: the world forwards the client's boot timing straight onto the telemetry batch — it is an
# account-level report, so it rides the onboarding intent set and never touches gameplay state.
func test_client_boot_timing_is_a_routed_intent_that_only_emits_telemetry() -> void:
	_make()
	var seen := _watch_funnel()
	assert_true(_rpc.handles("client_boot_timing"), "the world routes the boot report")
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(3.0, 3.0, 0.0))
	await (
		_rpc
		. handle(
			"client_boot_timing",
			10,
			{"launch_to_login_ms": 12000, "login_to_interactive_ms": 29000},
		)
	)
	assert_eq(_funnel_types(seen), ["client_boot_timing"])
	assert_eq(int(seen[0]["payload"]["launch_to_login_ms"]), 12000)
	assert_eq(_fm.calls.size(), 0, "no master round-trip — telemetry only")
	assert_eq(_replied.size(), 0, "and no reply to the client")


# T-705: a first equip is a beat; a bag op the master refuses is a reason. Both off one reply.
func test_equip_emits_the_beat_and_a_refused_bag_op_emits_its_reason() -> void:
	_make()
	var seen := _watch_funnel()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["equip"] = {"ok": true, "slots": []}
	await _rpc.handle("equip", 10, {"bag_slot": 0})
	assert_true(_funnel_types(seen).has("equip"), "the first-equip beat is measured")
	seen.clear()
	_fm.responses["drop"] = {"ok": false, "reason": "insufficient_count", "slots": []}
	await _rpc.handle("drop", 10, {"slot_type": "bag", "slot_index": 0, "count": 9})
	assert_eq(_funnel_types(seen), ["intent_rejected"])
	assert_eq(str(seen[0]["payload"]["reason"]), "insufficient_count")


# T-705: the trainer refusal that T-715 exists to prevent must be visible in the funnel.
func test_a_trainer_refusal_is_recorded_with_its_reason() -> void:
	_make()
	var seen := _watch_funnel()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(11.5, 8.5, 0.0))  # at Kessa's post
	_fm.responses["trainer_op"] = {"error": "insufficient_coins"}
	await _rpc.handle(
		"service_intent", 10, {"npc_id": "npc_trainer", "action": "train", "ability_id": 104}
	)
	assert_eq(_funnel_types(seen), ["intent_rejected"])
	assert_eq(str(seen[0]["payload"]["reason"]), "insufficient_coins")
	assert_eq(str(seen[0]["payload"]["intent"]), "trainer:starter:train")


func test_setup_bad_path_reports_error() -> void:
	var r = WorldRpc.new()
	assert_true(
		r.setup(FakeMaster.new(), func(_p, _d): pass, "res://nope") != "", "bad path errors"
	)


func test_handles_quest_and_inventory_intents() -> void:
	var r = WorldRpc.new()
	for m in [
		"request_quest_log",
		"accept_quest",
		"turn_in",
		"talk",
		"service_intent",
		"abandon",
		"get_inventory",
		"equip",
		"unequip",
		"drop",
		"wardrobe_list",
		"wardrobe_apply",
		"wardrobe_clear",
		"wardrobe_hide_helm",
	]:
		assert_true(r.handles(m), m)
	assert_false(r.handles("use_ability"))
	assert_false(r.handles("session"))


func test_handle_no_player_is_noop() -> void:
	_make()
	PlayerSessions._reset_for_test()
	_rpc.handle("get_inventory", 999, {})  # no player → early return, no master call, no reply
	assert_eq(_replied.size(), 0)
	assert_eq(_fm.calls.size(), 0)


func test_handle_equip_calls_master_and_replies_enriched() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	await _rpc.handle("equip", 10, {"bag_slot": 0})
	assert_eq(_fm.calls[0]["method"], "equip")
	assert_eq(_replied[0]["type"], "equip_result")


# T-399: equipping changes the effective gear set — the world re-derives combat stats through the
# master fold (with the item_stats registry injected) and pushes the refreshed sheet.
func test_equip_rederives_combat_stats_through_gear_fold() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["equip"] = {"ok": true, "slots": []}
	_fm.responses["get_character_combat"] = {"stats": {"str": 10, "attack": 8}}
	await _rpc.handle("equip", 10, {"bag_slot": 0})
	var gcc: Dictionary = {}
	for c in _fm.calls:
		if c["method"] == "get_character_combat":
			gcc = c
	assert_false(gcc.is_empty(), "equip re-derives combat stats from master")
	assert_true(
		gcc["params"].has("item_stats"), "the re-derive injects the world item_stats registry"
	)
	assert_eq(_applied.size(), 1, "gear-changed stats re-applied exactly once")
	assert_eq(int(_applied[0]["stats"]["attack"]), 8, "the folded gear attack reaches the apply cb")
	var sheet := _replied.filter(func(r): return r.get("type", "") == "player_stats")
	assert_eq(sheet.size(), 1, "the refreshed stat sheet is pushed to the peer")
	# T-642 (portal #86 family): equip is NOT a level-up — it must PRESERVE current hp, never heal.
	assert_true(bool(_applied[0]["preserve"]), "equip re-derive must not full-heal mid-combat")


# T-399: a failed equip must NOT re-derive (nothing changed).
func test_failed_equip_skips_rederive() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["equip"] = {"ok": false, "reason": "wrong_slot"}
	await _rpc.handle("equip", 10, {"bag_slot": 0})
	for c in _fm.calls:
		assert_ne(c["method"], "get_character_combat", "a rejected equip does not re-derive stats")
	assert_eq(_applied.size(), 0, "no stat re-apply on a failed equip")


# T-570 (report #25): equipping the item that credits q_tut_02's EQUIP objective must push a
# quest_delta to the peer immediately — before this fix the objective updated server-side but the
# client's tracker HUD stayed at 0/1 until an unrelated quest event happened to refresh it.
func test_equip_credit_pushes_quest_delta() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["equip"] = {
		"ok": true, "slots": [], "equipped_item": "itm_leather_cap", "equip_credited": ["q_tut_02"]
	}
	_fm.responses["quest_entry"] = {
		"entry": {"quest_id": "q_tut_02", "state": "active", "progress": [1]}
	}
	_fm.responses["get_quest_log"] = {
		"quests": [{"quest_id": "q_tut_02", "state": "active", "progress": [1]}], "level": 1
	}
	await _rpc.handle("equip", 10, {"bag_slot": 0})
	await get_tree().process_frame
	await get_tree().process_frame
	var deltas := _replied.filter(func(r): return r.get("type", "") == "quest_delta")
	assert_eq(deltas.size(), 1, "the equip credit pushes exactly one quest_delta")
	assert_eq(str(deltas[0]["quest_id"]), "q_tut_02", "the delta names the credited quest")


# T-570: an equip that credits NOTHING (result carries no "equip_credited") must not push a delta.
func test_equip_without_credit_skips_quest_delta() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["equip"] = {"ok": true, "slots": [], "equipped_item": "itm_plain_shirt"}
	await _rpc.handle("equip", 10, {"bag_slot": 0})
	await get_tree().process_frame
	var deltas := _replied.filter(func(r): return r.get("type", "") == "quest_delta")
	assert_eq(deltas.size(), 0, "no equip_credited means no quest_delta push")


# T-399: repairing broken gear restores its stats — the world re-derives combat stats after.
func test_repair_rederives_combat_stats() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(28.0, -108.0, 0.0))  # on the vendor
	_fm.responses["repair_op"] = {"ok": true, "coins": 90, "repaired": 2, "cost": 10}
	_fm.responses["get_character_combat"] = {"stats": {"str": 10, "attack": 8}}
	await _rpc.handle("service_intent", 10, {"npc_id": "npc_hk_vendor_general", "action": "repair"})
	var fetched := false
	for c in _fm.calls:
		if c["method"] == "get_character_combat":
			fetched = true
	assert_true(
		fetched, "a real repair re-derives combat stats (broken gear now contributes again)"
	)
	assert_eq(_applied.size(), 1, "repaired-gear stats re-applied once")
	# T-642 (portal #86 family): repairing gear at a vendor is NOT a level-up — it must never heal.
	assert_true(bool(_applied[0]["preserve"]), "repair re-derive must not full-heal mid-combat")


func test_accept_unknown_quest_replies_without_master() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	await _rpc.handle("accept_quest", 10, {"quest_id": "q_bogus"})
	assert_eq(_replied[0]["reason"], "unknown_quest")
	assert_eq(_fm.calls.size(), 0, "early return — no master call for an unknown quest")


func test_accept_known_quest_calls_master() -> void:
	_make()
	PlayerSessions._reset_for_test()
	# T-603: accept is now giver-proximity gated — stand at Farmer Geld (q001's giver, 4.8/1.5).
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(4.8, 1.5, 0.0))
	await _rpc.handle("accept_quest", 10, {"quest_id": "q001"})
	assert_eq(_fm.calls[0]["method"], "accept_quest")
	assert_eq(_replied[0]["type"], "accept_quest_result")
	for _frame in 4:  # let the accept's fire-and-forget delta/reach tails settle (see below)
		await get_tree().process_frame


# ---- T-603: accept_quest carries the same giver-proximity gate turn_in always had ----


# The exact backlog-audit repro: accepting from across the map (the Highkeep chain's giver is
# 150+ units from the village) must reject too_far WITHOUT ever reaching the master.
func test_accept_far_from_giver_rejects_too_far_without_master() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)  # village origin
	await _rpc.handle("accept_quest", 10, {"quest_id": "q013"})  # giver npc_hk_regent (0, -148)
	assert_eq(_replied[0]["type"], "accept_quest_result")
	assert_false(_replied[0]["ok"], "cross-map accept is rejected")
	assert_eq(_replied[0]["reason"], "too_far", "matches _talk's rejection convention")
	assert_eq(_fm.calls.size(), 0, "the master never hears an out-of-range accept")


# 50m away from the giver (crank-prep case): still too_far even inside the same zone.
func test_accept_50m_from_giver_rejects_too_far() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(54.8, 1.5, 0.0))  # 50m east of Geld
	await _rpc.handle("accept_quest", 10, {"quest_id": "q001"})
	assert_false(_replied[0]["ok"])
	assert_eq(_replied[0]["reason"], "too_far")
	assert_eq(_fm.calls.size(), 0)


# A WANDERING giver gates on its fixed post (T-577 anchor), not its live wander-ticked position —
# the drillmaster patrols waypoints but accepting at his anchor (12.5, 9.0) must always work.
# (T-707 retired q007; q_tut_01 is the drillmaster's remaining wandering-giver fixture.)
func test_accept_at_wandering_giver_anchor_ok() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(12.5, 9.0, 0.0))
	await _rpc.handle("accept_quest", 10, {"quest_id": "q_tut_01"})
	assert_eq(_fm.calls[0]["method"], "accept_quest", "anchor-based accept reaches the master")
	# A prior test's un-awaited delta tail can land in _replied first — filter for the accept.
	var accepts := _replied.filter(func(r): return r.get("type", "") == "accept_quest_result")
	assert_true(bool(accepts[0]["ok"]), "in-range accept succeeds")
	for _frame in 4:  # settle this accept's own fire-and-forget tails before the next test
		await get_tree().process_frame


# T-707: a retired quest (q007) takes no NEW accepts even from a forged in-range intent — the
# server gate, not just the hidden offer card. The master must never hear it.
func test_accept_retired_quest_rejects() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(12.5, 9.0, 0.0))
	await _rpc.handle("accept_quest", 10, {"quest_id": "q007"})
	var accepts := _replied.filter(func(r): return r.get("type", "") == "accept_quest_result")
	assert_false(bool(accepts[0]["ok"]), "retired accept is rejected")
	assert_eq(str(accepts[0]["reason"]), "quest_retired")
	assert_eq(_fm.calls.size(), 0, "the master never hears a retired accept")


# Bounty-board pickups (T-293) still work: the board is the giver and has a fixed anchor.
func test_accept_bounty_at_board_ok() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(0.0, -206.0, 0.0))  # on the HK board
	await _rpc.handle("accept_quest", 10, {"quest_id": "qb02"})
	assert_eq(_fm.calls[0]["method"], "accept_quest")
	var accepts := _replied.filter(func(r): return r.get("type", "") == "accept_quest_result")
	assert_true(bool(accepts[0]["ok"]), "board-anchored bounty accept still works")
	for _frame in 4:  # settle this accept's own fire-and-forget tails before the next test
		await get_tree().process_frame


# ---- T-689: an authored roost grant fires on ACCEPT (the sky-lane the text promises) ----


# Portal Bug #101: the solo spine's terminal quest says "ride the western sky-lane to the Ashmoor
# Sky Dock", but the Ashmoor roost was discoverable only by talking to the flightmaster who stands
# AT that dock — so the promised route was a chicken-and-egg lie and the real path was a 420 m walk
# across empty void. Accepting the quest now pre-seeds the roost through the ordinary discover verb.
func _flight_discoveries() -> Array:
	return _fm.calls.filter(
		func(c):
			return (
				str(c["method"]) == "flight_op" and str(c["params"].get("action", "")) == "discover"
			)
	)


func test_accepting_the_ashmoor_reach_quest_grants_the_ashmoor_roost() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(60.0, -30.0, 0.0))  # the Outpost Sentry
	await _rpc.handle("accept_quest", 10, {"quest_id": "q_wold_moor_road_ashmoor"})
	var accepts := _replied.filter(func(r): return r.get("type", "") == "accept_quest_result")
	assert_true(bool(accepts[0]["ok"]), "the accept itself still succeeds")
	var grants := _flight_discoveries()
	assert_eq(grants.size(), 1, "accepting the quest grants exactly one roost")
	assert_eq(
		str(grants[0]["params"]["node"]),
		"ashmoor",
		"the NODE id from flight_nodes.json, never the npc_id"
	)
	assert_eq(str(grants[0]["params"]["username"]), "alice", "granted to the accepting character")
	for _frame in 4:
		await get_tree().process_frame


# The grant is authored per-quest, not blanket: an ordinary quest grants no roost, and in particular
# the un-prereq'd L10 variant aimed at the SAME dock (q_wold_kingsroad_ashmoor) is untouched — a
# fresh L10 must not be handed a free era-2 flight (T-684 Work item 3 is still an open design call).
func test_ordinary_and_l10_variant_accepts_grant_no_roost() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(4.8, 1.5, 0.0))  # Farmer Geld, q001
	await _rpc.handle("accept_quest", 10, {"quest_id": "q001"})
	assert_eq(_flight_discoveries(), [], "a quest that promises no route grants no roost")
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(60.0, -30.0, 0.0))  # the Outpost Sentry
	await _rpc.handle("accept_quest", 10, {"quest_id": "q_wold_kingsroad_ashmoor"})
	assert_eq(_flight_discoveries(), [], "the L10 kingsroad variant is deliberately unchanged")
	for _frame in 4:
		await get_tree().process_frame


# ---- T-565: reach objectives level-trigger at accept time (portal report #19 softlock) ----


# T-603 x T-565: standing inside q001's reach radius (loc_old_well, 42/-13) but 40+ units from
# the giver — the accept now rejects too_far, so the accept-time level-trigger must NOT fire
# either (no credit for a quest that was never accepted). The positive accept-time-credit case
# lives in test_accept_q_tut_01_at_training_ring_center below, where the giver stands inside
# his own quest's reach radius.
func test_accept_inside_reach_radius_but_far_from_giver_rejects_and_credits_nothing() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(42, -13, 0.0))
	await _rpc.handle("accept_quest", 10, {"quest_id": "q001"})
	# credit_reach's push_quest_delta tail is un-awaited fire-and-forget and needs more than 2
	# frames to fully settle (same shape as the on_mob_kill tests above) — 2 frames left a pending
	# reply to bleed into whatever test ran next.
	for _frame in 4:
		await get_tree().process_frame
	assert_eq(_replied[0]["reason"], "too_far", "T-603: reach radius is not the giver's radius")
	var reach_calls := _fm.calls.filter(func(c): return c["method"] == "credit_reach")
	assert_eq(reach_calls.size(), 0, "a rejected accept never level-triggers reach credit")


# Regression: accepting from OUTSIDE the radius must not credit immediately, and walking in
# afterward (the existing edge-triggered path) must still credit exactly once — no double-credit.
func test_accept_quest_outside_radius_then_move_in_still_credits_once() -> void:
	_make()
	PlayerSessions._reset_for_test()
	# T-603: at the giver (so the accept passes) — still far from loc_old_well.
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(4.8, 1.5, 0.0))
	await _rpc.handle("accept_quest", 10, {"quest_id": "q001"})
	for _frame in 4:
		await get_tree().process_frame
	assert_eq(
		_fm.calls.filter(func(c): return c["method"] == "credit_reach").size(),
		0,
		"accepting outside the radius credits nothing yet"
	)
	_fm.calls = []
	_rpc.on_player_moved(10, "alice", Vector3(0, 0, 0.0), Vector3(42, -13, 0.0))  # walk in
	for _frame in 4:
		await get_tree().process_frame
	var reach_calls := _fm.calls.filter(func(c): return c["method"] == "credit_reach")
	assert_eq(reach_calls.size(), 1, "the normal walk-in path still credits exactly once")


# The exact portal-#19 scenario: q_tut_01's "Walk to the training ring" objective (loc_training_ring
# at x14,y10, radius 3) accepted from Drillmaster Hale, who stands well inside that same radius —
# a player who never crosses the boundary (idles, tiny circles, or their first move packet already
# lands inside) must still have this objective credited the instant they accept.
func test_accept_q_tut_01_at_training_ring_center_credits_reach_immediately() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(14.0, 10.0, 0.0))  # ring dead-center
	await _rpc.handle("accept_quest", 10, {"quest_id": "q_tut_01"})
	for _frame in 4:
		await get_tree().process_frame
	var reach_calls := _fm.calls.filter(func(c): return c["method"] == "credit_reach")
	assert_eq(reach_calls.size(), 1, "T-565: no softlock — reach credits without any movement")
	assert_eq(str(reach_calls[0]["params"]["target"]), "loc_training_ring")


# ---- T-145: service-hub stub intents (world-local ack; proximity + service gated) ----


func test_service_intent_browses_vendor_through_master_with_server_stock() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(28.0, -108.0, 0.0))  # on the vendor
	_fm.responses["vendor_op"] = {"ok": true, "wares": [], "bag": [], "buyback": [], "coins": 100}
	await _rpc.handle("service_intent", 10, {"npc_id": "npc_hk_vendor_general", "action": "browse"})
	assert_eq(_fm.calls.size(), 1, "vendor browse reaches master inventory/coin authority")
	assert_eq(str(_fm.calls[0]["method"]), "vendor_op")
	assert_eq(str(_fm.calls[0]["params"]["username"]), "alice", "identity comes from session")
	assert_true(
		(_fm.calls[0]["params"]["wares"] as Array).has("itm_potion_minor_healing"),
		"stock comes from this server-loaded NPC"
	)
	assert_eq(_replied[0]["type"], "service_ack")
	assert_true(_replied[0]["ok"], "vendor in range acks ok")
	assert_eq(_replied[0]["service"], "vendor")
	assert_eq(_replied[0]["action"], "browse")
	assert_true(_replied[0].has("buyback"), "vendor panel state rides the ack")


func test_vendor_sell_forwards_only_slot_desire_and_ignores_forged_authority() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(28.0, -108.0, 0.0))
	_fm.responses["vendor_op"] = {
		"ok": true,
		"wares": [],
		"bag": [],
		"buyback": [{"index": 0, "item_id": "itm_wolf_pelt", "count": 2, "price": 24}],
		"coins": 124,
		"sold": "itm_wolf_pelt",
		"count": 2,
		"price": 24,
	}
	await (
		_rpc
		. handle(
			"service_intent",
			10,
			{
				"npc_id": "npc_hk_vendor_general",
				"action": "sell",
				"slot_index": 3,
				"count": 999,
				"price": 999999,
				"character_id": 88,
				"wares": ["itm_maldrath_hollow_crown"],
			}
		)
	)
	var sent: Dictionary = _fm.calls[0]["params"]
	assert_eq(str(_fm.calls[0]["method"]), "vendor_op")
	assert_eq(str(sent["username"]), "alice")
	assert_eq(int(sent["slot_index"]), 3)
	assert_eq(int(sent["count"]), 999, "count is a desire; master clamps it to owned")
	for forbidden in ["price", "character_id"]:
		assert_false(sent.has(forbidden), "forged %s never crosses world->master" % forbidden)
	assert_true((sent["wares"] as Array).has("itm_potion_minor_healing"))
	assert_false((sent["wares"] as Array).has("itm_maldrath_hollow_crown"))
	assert_eq(int(_replied[0]["price"]), 24, "only master's computed price reaches client")
	assert_eq(int(_replied[0]["count"]), 2, "only master's clamped count reaches client")


func test_bounty_board_browse_returns_the_hunts() -> void:
	# T-450: world still owns the definitions; master supplies per-character claim/streak state.
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(0.0, -206.0, 0.0))  # on the Highkeep board
	_fm.responses["daily_status"] = {
		"ok": true,
		"date_key": "2026-07-15",
		"streak": 3,
		"objectives": [{"quest_id": "qb01", "title": "Greymaw", "claimed": false}],
		"first_bonus_available": true,
	}
	await _rpc.handle("service_intent", 10, {"npc_id": "npc_hk_bounty_board", "action": "browse"})
	assert_eq(_fm.calls.size(), 1, "daily state is read from the master authority")
	assert_eq(_fm.calls[0]["method"], "daily_status")
	assert_eq(_fm.calls[0]["params"]["username"], "alice", "identity came from the session")
	assert_true(_fm.calls[0]["params"].has("date_key"), "world injected the UTC date key")
	assert_true(_fm.calls[0]["params"]["quest_defs"].has("qb01"), "world injected content")
	assert_eq(_replied[0]["type"], "service_ack")
	assert_true(_replied[0]["ok"])
	assert_eq(_replied[0]["service"], "bounty")
	assert_true(_replied[0].has("bounties"), "the ack carries the bounty list")
	assert_eq((_replied[0]["bounties"] as Array).size(), 3, "all three elite hunts posted")
	assert_eq(int(_replied[0]["daily"]["streak"]), 3, "claimed/available daily state is exposed")


func test_service_intent_acks_inn_set_home() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(16.0, -106.0, 0.0))  # on the innkeeper
	await _rpc.handle("service_intent", 10, {"npc_id": "npc_hk_innkeeper", "action": "set_home"})
	assert_true(_replied[0]["ok"], "innkeeper in range acks set_home")
	assert_eq(_replied[0]["service"], "inn")
	assert_eq(_replied[0]["action"], "set_home")


func test_service_intent_rejections() -> void:
	# Same {ok:false, reason} shape as talk: unknown npc → out of range → NPC with no service.
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)  # far from the Market Ward
	await _rpc.handle("service_intent", 10, {"npc_id": "npc_bogus", "action": "browse"})
	assert_eq(_replied[-1]["reason"], "unknown_npc", "unknown npc rejected")
	await _rpc.handle("service_intent", 10, {"npc_id": "npc_hk_vendor_general", "action": "browse"})
	assert_eq(_replied[-1]["reason"], "too_far", "real service NPC but out of range rejected")
	# npc_farmer_geld sits at (5, 2) with no service tag — stand on him, still "no_service".
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(11, TOKEN, "bob", Vector3(5.0, 2.0, 0.0))
	await _rpc.handle("service_intent", 11, {"npc_id": "npc_farmer_geld", "action": "browse"})
	assert_eq(_replied[-1]["reason"], "no_service", "non-service NPC rejected")
	for r in _replied:
		assert_false(r["ok"], "every rejection acks ok=false")
		assert_eq(r["type"], "service_ack", "every rejection is a service_ack")
	assert_eq(_fm.calls.size(), 0, "rejections never touch the master")


func test_talk_result_carries_service_and_name() -> void:
	# T-145: talk_result propagates `service` (like `trainer`) + the NPC name so the client can
	# title + open the stub hub panel.
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(-33.0, -207.0, 0.0))  # by the banker (T-203: moved into the bank)
	_fm.responses["talk"] = {"talk_text": "vault", "indicator": "", "credited": []}
	await _rpc.handle("talk", 10, {"npc_id": "npc_hk_banker"})
	assert_eq(_replied[0]["type"], "talk_result")
	assert_eq(_replied[0]["service"], "bank", "talk_result carries the service tag")
	assert_eq(_replied[0]["name"], "Banker Coyne", "talk_result carries the NPC name")


func test_talking_to_flight_master_persists_roost_discovery() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(-12.0, -8.0, 0.0))
	_fm.responses["talk"] = {"talk_text": "Routes await.", "credited": []}
	_fm.responses["flight_op"] = {"ok": true, "known_nodes": ["village"], "coins": 100}
	await _rpc.handle("talk", 10, {"npc_id": "npc_village_flightmaster"})
	var discovery: Dictionary = {}
	for call in _fm.calls:
		if call["method"] == "flight_op":
			discovery = call
	assert_false(discovery.is_empty(), "flight-master talk reaches persisted discovery authority")
	assert_eq(str(discovery["params"]["action"]), "discover")
	assert_eq(str(discovery["params"]["node"]), "village")
	assert_eq(str(_replied[-1]["service"]), "flight", "normal talk reply still opens route UI")


func test_on_mob_kill_credits_connected_players() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	# q001 has a kill objective for mob_wolf → credit fires for the connected player.
	_rpc.on_mob_kill([10], "mob_wolf")
	# credit_kill_async's tail (push_quest_delta -> _push_npc_indicator_delta) is un-awaited
	# fire-and-forget and needs more than 2 frames to fully settle (matches the 4-frame idiom the
	# mob-XP tests below already use) — 2 frames left this test's own pending reply to bleed into
	# whatever ran next.
	for _frame in 4:
		await get_tree().process_frame
	assert_eq(_fm.calls[0]["method"], "credit_kill")
	# T-058: a credited kill pushes the targeted delta (one quest entry + affected NPCs).
	var methods: Array = _fm.calls.map(func(c): return c["method"])
	assert_true(methods.has("quest_entry"), "kill credit pushes the quest delta")
	assert_true(methods.has("get_quest_log"), "kill credit fetches small state for indicator delta")
	assert_false(methods.has("npc_indicators"), "kill credit never ships content to master")


# T-452 producer half: reward level is attached by the world service from live party truth. The
# client never supplies this field and cannot invoke on_mob_kill/credit_kill itself.
func test_on_mob_kill_forwards_server_derived_mentor_level() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "mentor", Vector3.ZERO)
	var store := PartyLogic.new_store()
	PartyLogic.invite(store, 10, 20)
	PartyLogic.accept(store, 20)
	var levels := {10: 40, 20: 5}
	var mentor := MentorshipService.new()
	mentor.setup(
		store,
		levels,
		func(_peer, _class, _stats, _talents, _level, _preserve = false): pass,
		func(_peer, _msg): pass
	)
	mentor.record_authoritative(10, "warrior", {"str": 127, "attack": 40}, {}, 40)
	mentor.record_authoritative(20, "warrior", {"str": 22}, {}, 5)
	mentor.toggle(10)
	_rpc._set_mentorship(mentor)
	_rpc.on_mob_kill([10], "mob_wolf", 40, 5, [10])
	for _frame in 4:  # let credit_kill_async's fire-and-forget tail fully settle (see above)
		await get_tree().process_frame
	var credit: Dictionary = {}
	for call in _fm.calls:
		if call["method"] == "credit_kill":
			credit = call
	assert_eq(int(credit["params"]["mentor_level"]), 5, "party minimum is the reward level")
	assert_true(bool(credit["params"]["mentor_opted_in"]), "opt-in is live service truth")
	assert_true(bool(credit["params"]["mentor_active"]), "a threat participant is active")
	_rpc.on_mob_kill([10], "mob_wolf", 40, 5, [])
	for _frame in 4:
		await get_tree().process_frame
	var afk_credit: Dictionary = _fm.calls.filter(func(call): return call["method"] == "credit_kill")[-1]
	assert_false(
		bool(afk_credit["params"]["mentor_active"]), "nearby AFK party credit is not mentoring"
	)


func test_on_mob_kill_never_forwards_forged_mentor_fields_without_live_sync() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "mentor", Vector3.ZERO)
	_rpc.on_mob_kill([10], "mob_wolf", 40, 5)
	for _frame in 4:
		await get_tree().process_frame
	var credit: Dictionary = _fm.calls.filter(func(call): return call["method"] == "credit_kill")[0]
	assert_false(credit["params"].has("mentor_opted_in"), "no service truth means no mentor claim")
	assert_false(credit["params"].has("mentor_level"))


func test_mob_xp_levelup_refreshes_authoritative_level_and_stats() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "mentor", Vector3.ZERO)
	_fm.responses["credit_kill"] = {
		"credited": [], "mob_xp": 40, "leveling": {"leveled_up": true, "level": 6}
	}
	_fm.responses["get_character_combat"] = {
		"class": "warrior", "level": 6, "stats": {"str": 25, "stamina": 25}
	}
	_rpc.on_mob_kill([10], "mob_wolf", 40, 5)
	for _frame in 4:
		await get_tree().process_frame
	var methods: Array = _fm.calls.map(func(call): return str(call["method"]))
	assert_true(methods.has("get_character_combat"), "level-up re-fetches persisted combat truth")
	assert_eq(int(_applied[-1]["level"]), 6, "new true level reaches world stat application")
	# T-642: a level-up kill is still allowed to fully heal (preserve=false) — unchanged behavior.
	assert_false(bool(_applied[-1]["preserve"]), "level-up kill legitimately refills resources")


# T-588 (portal report #46): a mob kill that grants XP WITHOUT a level-up must still push an
# updated player_stats to the client — otherwise the HUD XP bar stays frozen mid-grind until a
# kill happens to cross a level threshold. Mirrors the turn_in no-levelup test below.
func test_mob_kill_xp_no_levelup_still_refreshes_stats() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["credit_kill"] = {"credited": [], "mob_xp": 12, "leveling": {"leveled_up": false}}
	_fm.responses["get_character_combat"] = {
		"level": 3, "xp_into_level": 12, "xp_for_next_level": 100, "stats": {}
	}
	_rpc.on_mob_kill([10], "mob_wolf", 12, 3)
	for _frame in 4:
		await get_tree().process_frame
	assert_eq(_applied.size(), 0, "no stat re-apply without a level-up")
	var stats_msgs: Array = _replied.filter(func(r): return r.get("type", "") == "player_stats")
	assert_true(stats_msgs.size() >= 1, "mob-kill XP without a level-up still pushes player_stats")
	assert_eq(int(stats_msgs[0].get("xp_into_level", -1)), 12)


# Level-up still repushes stats too (the level-up branch stays intact alongside the new xp>0 one).
func test_mob_kill_levelup_still_refreshes_stats() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["credit_kill"] = {
		"credited": [], "mob_xp": 40, "leveling": {"leveled_up": true, "level": 6}
	}
	_fm.responses["get_character_combat"] = {
		"class": "warrior", "level": 6, "stats": {"str": 25, "stamina": 25}
	}
	_rpc.on_mob_kill([10], "mob_wolf", 40, 5)
	for _frame in 4:
		await get_tree().process_frame
	var stats_msgs: Array = _replied.filter(func(r): return r.get("type", "") == "player_stats")
	assert_true(stats_msgs.size() >= 1, "level-up kill still pushes player_stats")


# T-426: an empty ability slug must NOT call master (guard). A real slug now always matches the
# tutorial's "*" use_ability objective (q_tut_02), so the empty slug is the clean no-forward case.
func test_on_ability_used_empty_slug_skips_master() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_rpc._on_ability_used(10, "")
	await get_tree().process_frame
	await get_tree().process_frame
	var methods: Array = _fm.calls.map(func(c): return c["method"])
	assert_false(methods.has("credit_ability"), "empty slug → master is never called")


# T-426: a real ability slug matches the shipped tutorial "*" objective and forwards to master.
func test_on_ability_used_forwards_for_tutorial_wildcard() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_rpc._on_ability_used(10, "heroic_strike")
	await get_tree().process_frame
	await get_tree().process_frame
	var methods: Array = _fm.calls.map(func(c): return c["method"])
	assert_true(methods.has("credit_ability"), "the tutorial '*' objective forwards any ability")


# T-426 slice 4: an empty mob alias never reaches the master (guarded like the ability forward).
func test_on_cast_interrupted_empty_alias_skips_master() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_rpc._on_cast_interrupted(10, "")
	await get_tree().process_frame
	await get_tree().process_frame
	var methods: Array = _fm.calls.map(func(c): return c["method"])
	assert_false(methods.has("credit_interrupt"), "empty alias → master is never called")


# T-426 slice 4: interrupting the shipped training effigy forwards credit_interrupt to the master.
func test_on_cast_interrupted_forwards_for_effigy() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_rpc._on_cast_interrupted(10, "mob_training_effigy")
	await get_tree().process_frame
	await get_tree().process_frame
	var methods: Array = _fm.calls.map(func(c): return c["method"])
	assert_true(methods.has("credit_interrupt"), "q_tut_03's interrupt objective forwards")


func test_on_player_moved_edge_triggers_reach() -> void:
	_make()
	# q001's reach objective: loc_old_well at (42, -13), radius 3.
	_rpc.on_player_moved(10, "alice", Vector3(0, 0, 0.0), Vector3(42, -13, 0.0))  # enter the radius
	await get_tree().process_frame
	await get_tree().process_frame
	var reach_calls := _fm.calls.filter(func(c): return c["method"] == "credit_reach")
	assert_eq(reach_calls.size(), 1, "quest reach and landmark discovery can share a location")
	# T-058: a credited reach also pushes the targeted delta.
	var methods: Array = _fm.calls.map(func(c): return c["method"])
	assert_true(methods.has("quest_entry"), "reach credit pushes the quest delta")
	# Move within the radius again → no new credit (edge-triggered).
	_fm.calls = []
	_rpc.on_player_moved(10, "alice", Vector3(42, -13, 0.0), Vector3(43, -13, 0.0))
	await get_tree().process_frame
	assert_eq(_fm.calls.size(), 0, "no re-credit while staying inside")


func test_on_player_moved_edge_triggers_server_discovery_and_confirmed_toast() -> void:
	_make()
	_fm.responses["discover"] = {
		"discovered": true,
		"node": {"id": "ashmoor_arrival_plaza", "name": "Ashmoor Arrival Plaza", "lore": "Soot."},
		"xp": 150,
		"rested_bonus": 20,
		"leveling": {"leveled_up": false},
	}
	_fm.responses["get_character_combat"] = {"stats": {}, "level": 20}
	_rpc.on_player_moved(10, "alice", Vector3(-420, -11, 0), Vector3(-420, -7, 0))
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var discover_calls := _fm.calls.filter(func(c): return c["method"] == "discover")
	assert_eq(discover_calls.size(), 1, "authoritative movement edge forwards one authored node")
	assert_eq(str(discover_calls[0]["params"]["username"]), "alice")
	assert_eq(str(discover_calls[0]["params"]["node"]["id"]), "ashmoor_arrival_plaza")
	var toasts := _replied.filter(func(msg): return msg.get("type", "") == "discovery_earned")
	assert_eq(toasts.size(), 1, "only the master's confirmed first discovery reaches the client")
	assert_eq(int(toasts[0]["xp"]), 150)


func test_discovery_lingering_inside_radius_does_not_call_master() -> void:
	_make()
	_rpc.on_player_moved(10, "alice", Vector3(-420, -7, 0), Vector3(-420, -6, 0))
	await get_tree().process_frame
	assert_false(_fm.calls.map(func(c): return c["method"]).has("discover"))


func test_request_npc_indicators_routes_and_replies_enriched() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["get_quest_log"] = {"quests": [], "level": 1}
	await _rpc.handle("request_npc_indicators", 10, {})
	assert_eq(_fm.calls[0]["method"], "get_quest_log")
	assert_eq(_fm.calls[0]["params"], {"username": "alice"}, "content stays world-local")
	assert_eq(_replied[0]["type"], "npc_indicators")
	assert_true(_replied[0]["npcs"].size() >= 1, "NPCs enriched with name/position")
	assert_true(_replied[0]["npcs"][0].has("x"), "position included")
	for call in _fm.calls:
		assert_false(call["params"].has("npcs"), "no NPC registry crosses WS")
		assert_false(call["params"].has("quest_defs"), "no quest registry crosses WS")


# T-061: a turn-in that levels the player up refreshes their combat stats live (no relog).


func test_turn_in_levelup_refreshes_combat_stats() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["turn_in"] = {
		"ok": true, "reason": "", "xp": 100, "leveling": {"leveled_up": true}
	}
	_fm.responses["get_character_combat"] = {"stats": {"str": 13, "stamina": 13}}
	await _rpc.handle("turn_in", 10, {"quest_id": "q007"})
	var fetched := false
	for c in _fm.calls:
		if c["method"] == "get_character_combat":
			fetched = true
	assert_true(fetched, "level-up re-fetches combat stats from master")
	assert_eq(_applied.size(), 1, "stats re-applied once on level-up")
	assert_eq(_applied[0]["pid"], 10)
	assert_eq(int(_applied[0]["stats"]["str"]), 13, "refreshed stats passed to the apply callback")
	# T-642: a real level-up is the one repush event allowed to fully heal (preserve=false).
	assert_false(bool(_applied[0]["preserve"]), "level-up legitimately refills resources")


func test_turn_in_no_levelup_sends_xp_but_skips_stat_reapply() -> void:
	# T-060: XP gain without a level-up refreshes the XP bar (player_stats) but must NOT
	# re-apply combat stats (the T-061 seam stays level-up-only).
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["turn_in"] = {
		"ok": true, "reason": "", "xp": 50, "leveling": {"leveled_up": false}
	}
	_fm.responses["get_character_combat"] = {
		"level": 1, "xp_into_level": 50, "xp_for_next_level": 100, "stats": {}
	}
	await _rpc.handle("turn_in", 10, {"quest_id": "q007"})
	assert_eq(_applied.size(), 0, "no stat re-apply without a level-up")
	var stats_msgs: Array = _replied.filter(func(r): return r.get("type", "") == "player_stats")
	assert_eq(stats_msgs.size(), 1, "XP gain sends exactly one player_stats to the peer")
	assert_eq(int(stats_msgs[0].get("xp_into_level", -1)), 50)


func test_turn_in_zero_xp_skips_stats_message() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3.ZERO)
	_fm.responses["turn_in"] = {
		"ok": false, "reason": "objectives_incomplete", "xp": 0, "leveling": {}
	}
	await _rpc.handle("turn_in", 10, {"quest_id": "q007"})
	for c in _fm.calls:
		assert_ne(c["method"], "get_character_combat", "no re-fetch on a failed turn-in")
	assert_eq(
		_replied.filter(func(r): return r.get("type", "") == "player_stats").size(),
		0,
		"no player_stats without XP"
	)


func test_turn_in_forwards_coin_reward() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(0.0, -317.5, 0.0))
	_fm.responses["turn_in"] = {
		"ok": true,
		"xp": 400,
		"coins": 300,
		"leveling": {},
		"daily": {"bonus_granted": true, "reward": {"coins": 50}},
	}
	_fm.responses["get_character_combat"] = {}
	await _rpc.handle("turn_in", 10, {"quest_id": "q013"})
	var replies := _replied.filter(func(reply): return reply.get("type", "") == "turn_in_result")
	assert_eq(replies.size(), 1)
	assert_eq(int(replies[0].get("coins", 0)), 300, "base plus daily coin reward rides world reply")
	assert_true(replies[0]["daily"]["bonus_granted"])
	var turn_in_call: Dictionary = _fm.calls.filter(func(c): return c["method"] == "turn_in")[0]
	assert_true(turn_in_call["params"].has("date_key"), "turn-in injects the UTC daily key")
	assert_true(
		turn_in_call["params"]["quest_defs"].has("q013"), "content comes from world registry"
	)


# ---- T-058: npc-quest index + targeted delta push ----


func test_npc_quest_index_is_per_npc() -> void:
	_make()
	var index: Dictionary = _rpc.content_ops.build_npc_quest_index()
	# q001: giver/turnin npc_farmer_geld + talk target npc_scout_mira.
	assert_true(index["npc_farmer_geld"].has("q001"), "giver indexed")
	assert_true(index["npc_scout_mira"].has("q001"), "talk target indexed")
	# Bounded per-NPC cost: no NPC's subset is the full quest set + unrelated NPCs skip q001.
	assert_false(
		index.get("npc_outpost_guard", {}).has("q001"), "unrelated NPC does not carry q001"
	)
	# Bound scales with the busiest hub: Father Osric carries the T-357 capstone arc (5) +
	# crypt-entry + rift-crossing + the T-356 wold finale (8) + the T-719 tutorial capstone
	# (q_tut_04) = 9 — still a small per-NPC subset, not the whole quest set.
	for npc_id in index:
		assert_true(index[npc_id].size() <= 9, "each NPC indexes only its own quests (%s)" % npc_id)


func test_accept_pushes_targeted_deltas() -> void:
	_make()
	PlayerSessions._reset_for_test()
	# T-603: accept is giver-proximity gated — stand at Farmer Geld (q001's giver).
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(4.8, 1.5, 0.0))
	_fm.responses["accept_quest"] = {"ok": true, "reason": ""}
	_fm.responses["quest_entry"] = {
		"entry": {"quest_id": "q001", "state": "active", "progress": [0, 0, 0, 0]}
	}
	_fm.responses["get_quest_log"] = {
		"quests": [{"quest_id": "q001", "state": "active", "progress": [0, 0, 0, 0]}],
		"level": 1,
	}
	await _rpc.handle("accept_quest", 10, {"quest_id": "q001"})
	await get_tree().process_frame
	await get_tree().process_frame
	var types: Array = _replied.map(func(r): return str(r.get("type", "")))
	assert_true(types.has("quest_delta"), "accept pushes the one-quest delta")
	assert_true(types.has("npc_indicator_delta"), "accept pushes affected-NPC indicators")
	# The indicator push must remain targeted and content must never cross the WS seam.
	for c in _fm.calls:
		assert_ne(c["method"], "npc_indicators", "indicator content never crosses WS")


# ---- T-208: real service ops route through the master (escrow/vault/training) ----


func test_vault_intent_routes_to_master_and_acks_payload() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(-33.0, -207.0, 0.0))  # by the banker
	_fm.responses["vault_op"] = {"vault": [], "vault_slots": 12, "coins": 100}
	await _rpc.handle("service_intent", 10, {"npc_id": "npc_hk_banker", "action": "vault_list"})
	assert_eq(_fm.calls.size(), 1, "vault op goes to the master")
	assert_eq(str(_fm.calls[0]["method"]), "vault_op")
	assert_true(_replied[0]["ok"], "ack ok")
	assert_eq(int(_replied[0]["vault_slots"]), 12, "vault payload rides the ack")
	assert_eq(int(_replied[0]["coins"]), 100)


func test_auction_bid_error_surfaces_reason() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(33.6, -209.0, 0.0))  # by the auctioneer
	_fm.responses["auction_op"] = {"error": "bid_too_low"}
	await _rpc.handle(
		"service_intent",
		10,
		{"npc_id": "npc_hk_auctioneer", "action": "auction_bid", "auction_id": 1, "amount": 2}
	)
	assert_eq(str(_fm.calls[0]["method"]), "auction_op")
	assert_false(_replied[0]["ok"], "error surfaces")
	assert_eq(str(_replied[0]["reason"]), "bid_too_low")


# T-715: the hamlet trainer rides the SAME proximity-gated service flow as the capital trainers —
# the world forwards her starter tag untouched so the master can cap the tier it sells.
func test_starter_trainer_routes_the_starter_tag_to_master() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(11.5, 8.5, 0.0))  # at Kessa's post
	_fm.responses["trainer_op"] = {"catalog": [], "unlocked": [104], "coins": 105}
	await _rpc.handle(
		"service_intent", 10, {"npc_id": "npc_trainer", "action": "train", "ability_id": 104}
	)
	assert_eq(str(_fm.calls[0]["method"]), "trainer_op")
	assert_eq(str(_fm.calls[0]["params"]["service"]), "trainer:starter", "starter tag forwarded")
	assert_true(_replied[0]["ok"], "the hamlet purchase acks like any other trainer buy")
	assert_eq(_replied[0]["unlocked"], [104], "the new unlock rides the ack")
	# Out of range is still refused — the panel only opens for a player standing at her post.
	_fm.calls.clear()
	_replied.clear()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(60.0, 60.0, 0.0))
	await _rpc.handle("service_intent", 10, {"npc_id": "npc_trainer", "action": "catalog"})
	assert_eq(_fm.calls.size(), 0, "no master round-trip from across the hamlet")
	assert_eq(str(_replied[0]["reason"]), "too_far")


func test_trainer_train_and_vendor_browse_both_route_to_master() -> void:
	_make()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(94.5, -262.0, 0.0))  # mage trainer
	_fm.responses["trainer_op"] = {"catalog": [], "unlocked": [203], "coins": 40}
	await _rpc.handle(
		"service_intent",
		10,
		{"npc_id": "npc_hk_mage_trainer", "action": "train", "ability_id": 203}
	)
	assert_eq(str(_fm.calls[0]["method"]), "trainer_op")
	assert_true(_replied[0]["ok"])
	assert_eq(_replied[0]["unlocked"], [203], "unlock list rides the ack")
	# Vendor browse now routes to its own master authority.
	_fm.calls.clear()
	_replied.clear()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN, "alice", Vector3(28.0, -108.0, 0.0))
	_fm.responses["vendor_op"] = {"ok": true, "wares": [], "bag": [], "buyback": [], "coins": 100}
	await _rpc.handle("service_intent", 10, {"npc_id": "npc_hk_vendor_general", "action": "browse"})
	assert_eq(_fm.calls.size(), 1)
	assert_eq(str(_fm.calls[0]["method"]), "vendor_op")
	assert_true(_replied[0]["ok"])
