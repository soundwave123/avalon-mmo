# T-628 (the guarantee) + T-719 (the mechanism). The Hollowed Crypt originally had NO entry gate —
# a solo L7 walked into pack1's aggro cloud and died in a self-sustaining loop (the T-561 anomaly
# sentinel fired against itself: 3 deaths in 1200 ticks at the identical CRYPT_ENTRANCE coordinate).
# T-628 closed that by turning under-level entrants AWAY; T-719 keeps the guarantee but ROUTES
# them into the Shallow Graves (the tutorial capstone) instead, because a rejection left a new
# player with no dungeon at all. What is asserted here is unchanged in substance and stronger in
# form: a sub-CRYPT_MIN_LEVEL session is NEVER moved to CRYPT_ENTRANCE and never joins a crypt.
extends GutTest

const _ISVC = preload("res://scripts/instance_service.gd")
const _IM = preload("res://scripts/instance_manager.gd")
const _PL = preload("res://scripts/party_logic.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

var _moves: Dictionary = {}
var _replies: Array = []


func before_each() -> void:
	_moves = {}
	_replies = []
	PlayerSessions._reset_for_test()


func _noop1(_a) -> void:
	pass


func _noop2(_a, _b) -> void:
	pass


func _record_move(peer: int, pos: Vector3) -> void:
	_moves[peer] = pos


func _record_reply(_peer: int, data: Dictionary) -> void:
	_replies.append(data)


# A wired instance_service (no sessions -> _near_anchor's porch-proximity check auto-passes, the
# same unit-test bypass test_raid_instance.gd relies on). char_level defaults to {} (every peer
# reads as CRYPT_MIN_LEVEL — routing picks the crypt) unless a test wires one explicitly.
# party_store defaults to empty, so _crypt_kind_for falls back to the entrant's own level.
func _service(char_level: Dictionary = {}, party_store: Dictionary = {}) -> _ISVC:
	var svc = _ISVC.new()
	var party_of: Dictionary = party_store.get("party_of", _PL.new_store()["party_of"])
	svc.setup(
		{},
		party_of,
		Callable(self, "_noop2"),
		Callable(self, "_record_move"),
		Callable(self, "_noop1")
	)
	svc.setup_lfg({}, Callable(self, "_record_reply"), null, char_level)
	svc.setup_rift(party_store, Callable(), {})
	return svc


func _kind_of(svc: _ISVC, iid: int) -> String:
	return str(svc._instance_kind.get(iid, ""))


func _last_type() -> String:
	return "" if _replies.is_empty() else str(_replies[-1].get("type", ""))


# ---- The T-628 guarantee, kept: an under-level entrant never reaches the crypt ----


func test_under_level_entrant_is_routed_to_the_trial_not_the_crypt() -> void:
	var svc = _service({7: 7})  # the exact live repro: a level-7 solo entrant
	var iid: int = svc.enter(7)
	assert_gt(iid, _IM.WORLD, "they get a dungeon — T-719 routes instead of rejecting")
	assert_eq(_kind_of(svc, iid), svc.KIND_TRIAL, "and it is the Shallow Graves, not the crypt")
	assert_eq(_moves[7], svc.TRIAL_ENTRANCE, "landed at the trial vestibule")
	assert_ne(
		_moves[7], svc.CRYPT_ENTRANCE, "NEVER the crypt vestibule (the T-628 death-loop coord)"
	)


func test_a_fresh_graduate_takes_the_same_route() -> void:
	var svc = _service({4: 2})
	var iid: int = svc.enter(4)
	assert_eq(_kind_of(svc, iid), svc.KIND_TRIAL, "a level-2 tutorial graduate gets the capstone")
	assert_eq(_moves[4], svc.TRIAL_ENTRANCE)


func test_routing_notice_names_the_kind_so_the_client_can_explain_it() -> void:
	var svc = _service({4: 2})
	svc.enter(4)
	assert_eq(_last_type(), "instance_entered", "a positive notice, not an instance_denied")
	assert_eq(str(_replies[-1].get("kind", "")), svc.KIND_TRIAL)


func test_at_min_level_entry_still_opens_the_crypt() -> void:
	var svc = _service({12: 12})
	var iid: int = svc.enter(12)
	assert_gt(iid, _IM.WORLD, "a level-12 character still descends into the Hollowed Crypt")
	assert_eq(_kind_of(svc, iid), svc.KIND_CRYPT)
	assert_eq(_moves[12], svc.CRYPT_ENTRANCE, "the entrant lands at the crypt vestibule")


func test_unwired_peer_defaults_to_the_crypt() -> void:
	# No level ever recorded for this peer (matches most of the existing unit-test suite, which
	# never wires _char_level) — the crypt must stay the default so no other suite silently moves.
	var svc = _service({})
	var iid: int = svc.enter(99)
	assert_gt(iid, _IM.WORLD, "an unknown level defaults to admitted")
	assert_eq(_kind_of(svc, iid), svc.KIND_CRYPT, "…and to the crypt, exactly as before T-719")


# ---- Regression proof: the death-loop this ticket reported structurally cannot occur anymore ----
# qa_sentinel.gd's death_loop detector (T-561) fires on 3 deaths clustered near one POSITION,
# regardless of cause — it has no notion of "instance" or "level". The only way T-628's repro
# (3 deaths at the identical CRYPT_ENTRANCE coordinate) can happen is if a session under
# CRYPT_MIN_LEVEL is ever MOVED there. Proving that never happens is the structural guard.
func test_repeated_under_level_entries_never_reach_the_crypt_coordinate() -> void:
	var svc = _service({7: 7})
	for i in range(3):
		svc.enter(7)
		assert_ne(_moves[7], svc.CRYPT_ENTRANCE, "attempt %d still never lands in the crypt" % i)


# The trial respawn is the T-628 mistake inverted: a wipe puts the learner back at the vestibule
# anchor, which shallow_graves.json keeps >=7.1 m clear of every mob.
func test_a_trial_death_respawns_at_the_trial_vestibule() -> void:
	var svc = _service({7: 7})
	svc.enter(7)
	assert_eq(svc.respawn_point(7), svc.TRIAL_ENTRANCE)


func test_leaving_the_trial_returns_to_the_churchyard() -> void:
	var svc = _service({7: 7})
	svc.enter(7)
	svc.leave(7)
	assert_eq(_moves[7], svc.TRIAL_EXIT, "back out onto the churchyard surface")


# ---- The no-role-scarcity rule at the door: the party's LOWEST level decides ----


func _party_store_with(members: Array) -> Dictionary:
	var store: Dictionary = _PL.new_store()
	store["parties"][1] = {"members": members, "leader": int(members[0])}
	for m in members:
		store["party_of"][int(m)] = 1
	return store


func test_a_high_level_friend_is_pulled_into_the_trial_not_the_crypt() -> void:
	# The whole point of "bring anyone": a L20 helping a L2 through their first dungeon must end up
	# in the SAME instance as the L2 — and it must be the one the L2 can survive.
	var store := _party_store_with([1, 2])
	var svc = _service({1: 20, 2: 2}, store)
	var leader_iid: int = svc.enter(1)
	assert_eq(
		_kind_of(svc, leader_iid), svc.KIND_TRIAL, "the L20 leader is routed by the L2's level"
	)
	assert_eq(svc.enter(2), leader_iid, "and the L2 joins the very same instance")
	assert_eq(_moves[1], svc.TRIAL_ENTRANCE)
	assert_eq(_moves[2], svc.TRIAL_ENTRANCE)


func test_an_all_max_level_party_still_gets_the_crypt() -> void:
	var store := _party_store_with([1, 2])
	var svc = _service({1: 20, 2: 14}, store)
	var iid: int = svc.enter(1)
	assert_eq(_kind_of(svc, iid), svc.KIND_CRYPT)
	assert_eq(svc.enter(2), iid, "the second member joins the same crypt instance")
