extends GutTest
# T-331: soft-instance membership store (pure) — the full enter/leave/teardown transition matrix
# the crypt needs: enter with a party, leave, disband inside, death+respawn, a second party at the
# entrance. Mirrors test_party_logic.gd — no scene tree, no OS time.

const _IM = preload("res://scripts/instance_manager.gd")


func test_solo_entrant_gets_a_private_instance() -> void:
	var s := _IM.new_store()
	var r := _IM.enter(s, 1, -1)  # party_id -1 == solo
	assert_true(r["created"], "a solo entrant allocates a fresh instance")
	assert_gt(int(r["instance_id"]), _IM.WORLD, "instance id is non-zero (not the open world)")
	assert_eq(_IM.instance_of(s, 1), int(r["instance_id"]), "peer is now scoped to it")


func test_two_solos_get_independent_instances() -> void:
	var s := _IM.new_store()
	var a := int(_IM.enter(s, 1, -1)["instance_id"])
	var b := int(_IM.enter(s, 2, -1)["instance_id"])
	assert_ne(a, b, "two solo players never share an instance")
	assert_eq(_IM.instance_count(s), 2)


func test_party_second_member_joins_the_same_instance() -> void:
	var s := _IM.new_store()
	var first := _IM.enter(s, 1, 7)  # both peers are in party 7
	assert_true(first["created"], "the first party member allocates the instance")
	var second := _IM.enter(s, 2, 7)
	assert_false(second["created"], "the second party member JOINS, does not allocate")
	assert_eq(int(first["instance_id"]), int(second["instance_id"]), "same instance for the party")
	assert_eq(_IM.instance_count(s), 1, "one instance for the whole party")


func test_enter_is_idempotent() -> void:
	var s := _IM.new_store()
	var iid := int(_IM.enter(s, 1, 7)["instance_id"])
	var again := _IM.enter(s, 1, 7)
	assert_false(again["created"], "re-entering does not re-allocate")
	assert_eq(int(again["instance_id"]), iid)
	assert_eq(_IM.members(s, iid).size(), 1, "the peer is not double-added")


func test_last_member_out_tears_down_and_frees_spawns() -> void:
	var s := _IM.new_store()
	var iid := int(_IM.enter(s, 1, 7)["instance_id"])
	_IM.enter(s, 2, 7)
	_IM.set_spawns(s, iid, [50001, 50002, 50003])
	var r1 := _IM.leave(s, 1)
	assert_false(r1["torn_down"], "one of two leaving does not tear the instance down")
	assert_eq(r1["freed_spawns"], [], "and frees no spawns while a member remains")
	assert_eq(_IM.members(s, iid), [2], "peer 2 still inside")
	var r2 := _IM.leave(s, 2)
	assert_true(r2["torn_down"], "the LAST member out tears it down")
	assert_eq(r2["freed_spawns"], [50001, 50002, 50003], "and returns exactly the seeded spawns")
	assert_eq(_IM.instance_count(s), 0, "the instance is gone")
	assert_eq(_IM.instance_of(s, 2), _IM.WORLD, "and the peer is back in the open world")


func test_disband_inside_keeps_the_instance_until_all_leave() -> void:
	# A party disbands mid-crypt. Membership is decoupled from the party (instance_manager never
	# reads the party after entry), so both keep fighting until each walks out — the instance
	# survives on its remaining members, not on the now-dead party key.
	var s := _IM.new_store()
	var iid := int(_IM.enter(s, 1, 9)["instance_id"])
	_IM.enter(s, 2, 9)
	# (party 9 disbands in party_logic — no call into instance_manager at all)
	assert_eq(_IM.members(s, iid).size(), 2, "both remain instanced after the party dissolves")
	assert_false(_IM.leave(s, 1)["torn_down"], "first ex-member leaves, instance stands")
	assert_true(_IM.leave(s, 2)["torn_down"], "instance tears down only when the last walks out")


func test_death_and_respawn_preserve_instance_membership() -> void:
	# Death/respawn touch position + combat state, never the membership store — a corpse run stays
	# inside the crypt. Modeled here as: no leave() fires on death, so instance_of is unchanged.
	var s := _IM.new_store()
	var iid := int(_IM.enter(s, 1, 3)["instance_id"])
	# ... player dies and respawns (no store mutation) ...
	assert_eq(_IM.instance_of(s, 1), iid, "the respawned player is still bound to the instance")


func test_second_party_at_the_entrance_is_isolated() -> void:
	# Two parties both descend the stair: distinct instances, each member scoped to its own.
	var s := _IM.new_store()
	var a := int(_IM.enter(s, 1, 100)["instance_id"])  # party A = {1,2}
	_IM.enter(s, 2, 100)
	var b := int(_IM.enter(s, 3, 200)["instance_id"])  # party B = {3,4}
	_IM.enter(s, 4, 200)
	assert_ne(a, b, "the two parties get two different instances")
	assert_eq(_IM.instance_of(s, 1), a)
	assert_eq(_IM.instance_of(s, 2), a)
	assert_eq(_IM.instance_of(s, 3), b)
	assert_eq(_IM.instance_of(s, 4), b)
	assert_eq(_IM.instance_count(s), 2)


func test_leave_on_a_world_peer_is_a_noop() -> void:
	var s := _IM.new_store()
	var r := _IM.leave(s, 42)  # never entered anything
	assert_eq(int(r["instance_id"]), _IM.WORLD)
	assert_false(r["torn_down"])
	assert_eq(r["freed_spawns"], [])


func test_rejoin_after_full_teardown_allocates_fresh() -> void:
	# Re-entering with the same party after everyone left seeds a NEW instance (fresh trash).
	var s := _IM.new_store()
	var first := int(_IM.enter(s, 1, 7)["instance_id"])
	_IM.leave(s, 1)  # torn down
	var r := _IM.enter(s, 1, 7)
	assert_true(r["created"], "the party key was released on teardown, so re-entry re-allocates")
	assert_ne(int(r["instance_id"]), first, "and it is a brand-new instance id")
