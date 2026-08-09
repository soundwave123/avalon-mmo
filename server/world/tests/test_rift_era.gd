# T-347: the era-rift crossing through instance_service (enter_era / leave_era). Proves the rift
# is an OPEN/SHARED teleport — a pure session move to Ashmoor (instance_id 0), NOT a crypt-style
# instance alloc — and the honest reuse of the crypt teleport plumbing (the same _move_session /
# _set_session_instance callables). Recording callables capture what the service asked the live
# session layer to do.

extends GutTest

const _ISVC = preload("res://scripts/instance_service.gd")
const _IM = preload("res://scripts/instance_manager.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")  # T-369: DEAD-cross reject
const _PL = preload("res://scripts/party_logic.gd")  # T-369: auto-drop on cross
const PlayerSessions = preload("res://scripts/player_sessions.gd")  # T-352: gate resolves username
const _VALID_TOKEN := "abcdef0123456789abcdef0123456789"  # gitleaks:allow — hex session token
const _VALID_TOKEN2 := "0123456789abcdef0123456789abcdef"  # gitleaks:allow — a 2nd distinct token


# T-352: a fake MasterClient whose call_master returns a canned quest_entry, so the rift gate can
# be exercised without a live master. call_master is a plain func (await on a non-coroutine just
# returns it).
class _FakeMaster:
	var state: String = ""  # the state reported for EVERY quest_id (the pre-T-684 single-key shape)
	# T-684: per-quest states, so a character can hold ONE of the two capstones and not the other.
	# Falls back to `state` for any quest_id not named here.
	var states: Dictionary = {}
	var calls: Array = []

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append([method, params])
		var quest_id := str(params.get("quest_id", ""))
		var reported: String = str(states.get(quest_id, state))
		var entry: Dictionary = {}
		if reported != "":
			entry = {"state": reported}
		return {"entry": entry}


var _inst_calls: Array = []  # [[peer, iid], ...] from _set_session_instance
var _move_calls: Array = []  # [[peer, pos], ...] from _move_session
var _replies: Array = []  # [[peer, dict], ...] captured from the reject path
var _notify_calls: Array = []  # T-369: [affected_members, ...] from the party-frame notifier
var _discovery_calls: Array = []  # T-427: forced teleport old/new movement observations


func _rec_instance(peer: int, iid: int) -> void:
	_inst_calls.append([peer, iid])


func _rec_move(peer: int, pos: Vector3) -> void:
	_move_calls.append([peer, pos])


func _noop1(_a) -> void:
	pass


func _rec_discovery(peer: int, username: String, old_pos: Vector3, new_pos: Vector3) -> void:
	_discovery_calls.append([peer, username, old_pos, new_pos])


func before_each() -> void:
	_inst_calls = []
	_move_calls = []
	_discovery_calls = []
	# T-380: enter()/leave_era() are proximity-gated on the peer's live session; clear the static
	# store so peer 1 (used by the pure-move contract tests) has no session → the gate is bypassed,
	# preserving the "pure session move" contract regardless of suite ordering.
	PlayerSessions._reset_for_test()


func _svc() -> Object:
	var svc = _ISVC.new()
	var mobs: Dictionary = {}
	var party_of := {1: -1}
	svc.setup(
		mobs,
		party_of,
		Callable(self, "_rec_instance"),
		Callable(self, "_rec_move"),
		Callable(self, "_noop1")
	)
	return svc


func test_handles_the_era_intents() -> void:
	var svc = _svc()
	assert_true(svc.handles("enter_era"))
	assert_true(svc.handles("leave_era"))
	# and still handles the crypt intents (no regression)
	assert_true(svc.handles("enter_instance"))
	assert_true(svc.handles("leave_instance"))


func test_enter_era_from_world_is_a_pure_move_to_ashmoor() -> void:
	var svc = _svc()
	svc.enter_era(1)
	# session set to the OPEN world (instance 0), NOT a new instance id
	assert_eq(_inst_calls, [[1, _IM.WORLD]])
	# moved to the Ashmoor arrival plaza
	assert_eq(_move_calls, [[1, _ISVC.ASHMOOR_ARRIVAL]])


func test_enter_era_from_an_instance_drops_membership_first() -> void:
	var svc = _svc()
	svc.enter(1)  # peer 1 enters the crypt instance (allocs instance 1, seeds spawns)
	assert_ne(_IM.instance_of(svc._store, 1), _IM.WORLD)
	_inst_calls = []
	_move_calls = []
	svc.enter_era(1)
	# left the crypt instance -> now bound to the open world
	assert_eq(_IM.instance_of(svc._store, 1), _IM.WORLD)
	assert_eq(_inst_calls, [[1, _IM.WORLD]])
	assert_eq(_move_calls, [[1, _ISVC.ASHMOOR_ARRIVAL]])


func test_leave_era_returns_to_the_vault_surface_in_the_open_world() -> void:
	var svc = _svc()
	svc.leave_era(1)
	assert_eq(_inst_calls, [[1, _IM.WORLD]])
	assert_eq(_move_calls, [[1, _ISVC.RIFT_RETURN]])


# --- T-352: the rift ELIGIBILITY GATE ------------------------------------------------------------
func _rec_reply(peer: int, msg: Dictionary) -> void:
	_replies.append([peer, msg])


func _gated_svc(state: String, states: Dictionary = {}) -> Object:
	var svc = _svc()
	var master := _FakeMaster.new()
	master.state = state
	master.states = states  # T-684: per-capstone states; {} keeps the old blanket behaviour
	svc.setup_lfg({}, Callable(self, "_rec_reply"), master)
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(4242, _VALID_TOKEN, "rift_hero")
	return svc


func test_enter_era_blocks_a_player_without_the_arrival_quest() -> void:
	_replies = []
	var svc = _gated_svc("")  # no q_rift_vault_counted row -> not eligible
	await svc.enter_era(4242)
	assert_eq(_move_calls, [], "an ineligible player is NOT moved to Ashmoor")
	assert_eq(_inst_calls, [], "an ineligible player's session is untouched")
	assert_eq(_replies.size(), 1, "the blocked player is told the rift is sealed")
	assert_eq(str(_replies[0][1].get("type", "")), "rift_sealed")


func test_enter_era_allows_a_player_with_the_arrival_quest_active() -> void:
	var svc = _gated_svc("active")  # Osric has sent them -> eligible
	await svc.enter_era(4242)
	assert_eq(_move_calls, [[4242, _ISVC.ASHMOOR_ARRIVAL]], "an eligible player crosses to Ashmoor")


func test_enter_era_forwards_authoritative_teleport_to_discovery_observer() -> void:
	var svc = _gated_svc("active")
	PlayerSessions.update_position(4242, Vector3(424.3, -45.3, 0.0))
	# T-445: the session store seats positions on the TerrainField (relief != flat 0), so the
	# observer contract is "the STORED position" — read it back rather than assuming the input.
	var stored_pos: Vector3 = PlayerSessions.get_player(4242).get("pos", Vector3.ZERO)
	svc.setup_discovery(Callable(self, "_rec_discovery"))
	await svc.enter_era(4242)
	assert_eq(
		_discovery_calls,
		[[4242, "rift_hero", stored_pos, _ISVC.ASHMOOR_ARRIVAL]],
		"server teleport uses the same discovery edge contract as ordinary movement"
	)


func test_enter_era_allows_a_returning_player_who_already_completed_the_quest() -> void:
	var svc = _gated_svc("complete")
	await svc.enter_era(4242)
	assert_eq(_move_calls, [[4242, _ISVC.ASHMOOR_ARRIVAL]], "a completed-quest player may re-cross")


# --- T-684: the rift is a PARALLEL key — either capstone earns the crossing ---------------------


# The bug this closes: a solo player who ran T-627's crypt-free spine to its terminal quest holds NO
# crypt row at all, and the pre-T-684 gate queried only q_rift_vault_counted — so the quest that
# *sends* them to Ashmoor sealed the only door its own text promises.
func test_enter_era_allows_the_solo_spine_capstone_without_any_crypt_row() -> void:
	var svc = _gated_svc("", {"q_wold_moor_road_ashmoor": "active"})
	await svc.enter_era(4242)
	assert_eq(
		_move_calls,
		[[4242, _ISVC.ASHMOOR_ARRIVAL]],
		"the solo spine's own terminal quest is a passage grant"
	)


# Regression (T-684 DoD): the GROUP gate is not widened — the crypt capstone alone still crosses,
# exactly as before, with no solo row present.
func test_enter_era_still_allows_the_crypt_capstone_alone() -> void:
	var svc = _gated_svc("", {"q_rift_vault_counted": "active"})
	await svc.enter_era(4242)
	assert_eq(_move_calls, [[4242, _ISVC.ASHMOOR_ARRIVAL]], "the crypt chain still earns its key")


# ...and holding NEITHER capstone is still sealed — including the un-prereq'd L10 kingsroad variant,
# which is deliberately NOT a key (a fresh L10 must not hold an era-2 pass; T-684 Work item 3).
func test_enter_era_still_seals_a_player_holding_only_the_l10_kingsroad_variant() -> void:
	_replies = []
	var svc = _gated_svc("", {"q_wold_kingsroad_ashmoor": "complete"})
	await svc.enter_era(4242)
	assert_eq(_move_calls, [], "an un-prereq'd L10 quest is not a rift key")
	assert_eq(str(_replies[0][1].get("type", "")), "rift_sealed")


func test_ashmoor_is_the_far_west_offset_region_clear_of_the_crypt() -> void:
	# the arrival is r>330 (past the flat-plain LOD cull) and in the far WEST (x<0), maximally clear
	# of the crypt's +420 east region — the sightline-seal invariant (ashmoor-direction.md S1).
	var arr := _ISVC.ASHMOOR_ARRIVAL
	assert_lt(arr.x, 0.0)
	assert_gt(Vector2(arr.x, arr.y).length(), 330.0)


# --- T-369: rift/era EDGE CASES ------------------------------------------------------------------
func _rec_notify(peers: Array) -> void:
	_notify_calls.append(peers)


func _dead_state() -> Object:
	var cs = _CS.new()
	cs.state = _CS.CombatStateEnum.DEAD
	return cs


# CASE 2 — a DEAD player cannot cross the rift (the crossing is atomic w.r.t. combat state). No
# session move, and the actor is told the rift is sealed with reason "dead".
func test_enter_era_rejects_a_dead_player() -> void:
	_replies = []
	var svc = _svc()
	svc.setup_lfg({}, Callable(self, "_rec_reply"))  # capture the reject reply (no master -> ungated)
	svc.setup_rift({}, Callable(), {7: _dead_state()})
	await svc.enter_era(7)
	assert_eq(_move_calls, [], "a dead player is NOT teleported across the rift")
	assert_eq(_inst_calls, [], "a dead player's session scope is untouched")
	assert_eq(_replies.size(), 1, "the dead player is told the rift is sealed")
	assert_eq(str(_replies[0][1].get("reason", "")), "dead")


# CASE 2 — a live player with the rift wiring present still crosses (the DEAD gate is not a
# regression on the normal ungated pure-move path).
func test_enter_era_still_crosses_a_live_player_with_rift_wiring() -> void:
	var svc = _svc()
	svc.setup_rift({}, Callable(), {})  # no combat state -> alive
	await svc.enter_era(1)
	assert_eq(_move_calls, [[1, _ISVC.ASHMOOR_ARRIVAL]], "a live player still crosses")


# CASE 1 — crossing the rift AUTO-DROPS the crosser from their party (spike rule). The remaining
# members keep the party; the crosser is party-less; every affected member is re-notified.
func test_enter_era_auto_drops_the_crosser_from_their_party() -> void:
	_notify_calls = []
	var store := {
		"parties": {1: {"leader": 10, "members": [10, 11, 12]}},
		"party_of": {10: 1, 11: 1, 12: 1},
		"pending": {},
		"next_id": 2,
	}
	var svc = _svc()
	svc.setup_rift(store, Callable(self, "_rec_notify"), {})
	await svc.enter_era(11)  # peer 11 crosses
	assert_false(store["party_of"].has(11), "the crosser is dropped from the party roster")
	assert_eq(store["parties"][1]["members"], [10, 12], "the two non-crossers keep the party")
	assert_eq(_notify_calls.size(), 1, "affected members are re-notified once")
	assert_true(11 in _notify_calls[0], "the notify snapshot includes the crosser (frame clears)")
	assert_true(10 in _notify_calls[0] and 12 in _notify_calls[0], "and the remaining members")


# CASE 1 — a solo (party-less) crosser is a no-op for the party path (no notify, no crash).
func test_enter_era_solo_crosser_touches_no_party() -> void:
	_notify_calls = []
	var svc = _svc()
	svc.setup_rift(
		{"parties": {}, "party_of": {}, "pending": {}, "next_id": 1},
		Callable(self, "_rec_notify"),
		{}
	)
	await svc.enter_era(1)
	assert_eq(_notify_calls, [], "a solo crosser triggers no party notify")


# CASE 3 — a death in the ERA-2 Ashmoor region respawns at the Ashmoor graveyard, NOT the era-1
# origin nor the crypt vestibule.
func test_respawn_in_ashmoor_uses_the_era2_point() -> void:
	var svc = _svc()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(20, _VALID_TOKEN, "ash", _ISVC.ASHMOOR_ARRIVAL)
	assert_eq(svc.respawn_point(20), _ISVC.ASHMOOR_RESPAWN)


# CASE 3 — a death in the ERA-1 open world (village) still respawns at the world origin (as-is).
func test_respawn_in_era1_world_uses_the_origin() -> void:
	var svc = _svc()
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(21, _VALID_TOKEN2, "vil", Vector3(5.0, 5.0, 0.0))
	assert_eq(svc.respawn_point(21), Vector3.ZERO)


# CASE 3 — a death bound to a crypt instance still respawns at the crypt entrance (corpse run),
# regardless of era region — instance scope wins over the open-world era test.
func test_respawn_in_crypt_uses_the_entrance() -> void:
	var svc = _svc()
	_IM.enter(svc._store, 22, -1)  # bind peer 22 to a private crypt instance
	assert_ne(_IM.instance_of(svc._store, 22), _IM.WORLD)
	assert_eq(svc.respawn_point(22), _ISVC.CRYPT_ENTRANCE)
