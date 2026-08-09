extends GutTest

# T-698 fix 1c: the per-player ~4 Hz reach/discovery throttle in reach_service.gd. The invariant:
# throttling the CHECK cadence does NOT change which reach objectives credit, because the crossing
# edge (outside->inside) is preserved — the throttle's anchor IS the last position that was tested,
# so a fast pass through a radius still shows up as new_pos-inside / anchor-outside on the next
# sampled tick. Uses a fake master that records every credit_reach target it is asked to credit.

const _RS = preload("res://scripts/reach_service.gd")
const _CQ = preload("res://scripts/content/content_query.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")

# q001's reach objective: loc_old_well at (42, -13), radius 3.
const WELL := Vector3(42.0, -13.0, 0.0)

var _reach_objs: Array
var _quest_defs: Dictionary


class FakeMaster:
	var credited: Array = []  # every target handed to credit_reach

	# A coroutine, so reach_service's `await _master.call_master(...)` resolves like the real one.
	func call_master(method: String, params: Dictionary) -> Dictionary:
		await Engine.get_main_loop().process_frame
		if method == "credit_reach":
			credited.append(str(params.get("target", "")))
			return {"credited": []}  # no live quest state — we only assert WHICH targets were tried
		return {}


func before_all() -> void:
	var loaded := _CONTENT.load_all("res://data")
	_reach_objs = _CQ.reach_objectives(loaded["quests"])
	_quest_defs = _CQ.all_quest_defs(loaded["quests"])


func _service(fm) -> Object:
	var rs = _RS.new()
	rs.setup(
		fm,
		func(_p, _d): pass,
		func(_p, _u, _q): pass,
		func(_p, _r): pass,
		func(_p, _u, _a, _r): pass,
		[],
		_reach_objs,
		_quest_defs
	)
	return rs


func test_first_move_is_checked_immediately() -> void:
	# No window to anchor against yet — the very first move a session makes must check the true
	# edge (so single-shot test moves and teleport hops credit exactly).
	var fm = FakeMaster.new()
	var rs = _service(fm)
	rs.on_player_moved(1, "Ruin", Vector3(42.0, -16.5, 0.0), WELL, 0)  # steps INTO the well radius
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true("loc_old_well" in fm.credited, "first move crosses the edge and is checked at once")


func test_within_window_small_steps_fold_then_credit_on_the_next_sample() -> void:
	# The continuous-walk case the throttle targets: sub-1 u steps. Anchor just OUTSIDE the well
	# radius (dist 3.2), then a within-window small step INTO it (dist 2.9). That intra-window step
	# is folded (no check). The next post-window small step credits via anchor(outside)->new(inside).
	var fm = FakeMaster.new()
	var rs = _service(fm)
	# First move (small, both outside) sets the checkpoint anchor at (45.2, -13).
	rs.on_player_moved(1, "Ruin", Vector3(45.5, -13.0, 0.0), Vector3(45.2, -13.0, 0.0), 0)
	await get_tree().process_frame
	await get_tree().process_frame
	fm.credited.clear()
	# Within the 250 ms window: a 0.3 u step that crosses INTO the radius — folded, no check yet.
	rs.on_player_moved(1, "Ruin", Vector3(45.2, -13.0, 0.0), Vector3(44.9, -13.0, 0.0), 100)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(fm.credited, [], "a sub-1u step inside the throttle window runs no containment check")
	# Window elapsed: anchor(45.2 outside) -> new(44.8 inside) credits the crossing it deferred.
	rs.on_player_moved(1, "Ruin", Vector3(44.9, -13.0, 0.0), Vector3(44.8, -13.0, 0.0), 300)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true("loc_old_well" in fm.credited, "the folded crossing credits on the next sample")


func test_a_single_hop_that_ends_inside_is_never_stranded() -> void:
	# The T-320 regression the multi-client E2E caught: a discrete hop (teleport/rift/reach-harness)
	# ends inside a radius with NO follow-up move. It must be checked on its own edge (hop bypass),
	# not folded into a next sample that never arrives. Anchor first (small), then a >1u hop in.
	var fm = FakeMaster.new()
	var rs = _service(fm)
	rs.on_player_moved(1, "Ruin", Vector3(60.5, -13.0, 0.0), Vector3(60.2, -13.0, 0.0), 0)  # anchor
	await get_tree().process_frame
	await get_tree().process_frame
	fm.credited.clear()
	# Immediately (well inside the 250 ms window) a big hop lands on the well and the player stops.
	rs.on_player_moved(1, "Ruin", Vector3(60.2, -13.0, 0.0), WELL, 30)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(
		"loc_old_well" in fm.credited, "a hop ending inside a radius credits, never stranded"
	)


func test_edge_is_measured_against_the_anchor_not_the_immediate_old_pos() -> void:
	# The anchor property: after folding intra-window steps, the crossing is judged against the
	# LAST-CHECKED position (the anchor), not the immediate previous message. Here the post-window
	# sample's own old_pos is ALREADY inside (folded steps walked in), yet it still credits because
	# the anchor was outside — proving the throttle never loses a crossing to sampling.
	var fm = FakeMaster.new()
	var rs = _service(fm)
	rs.on_player_moved(1, "Ruin", Vector3(45.6, -13.0, 0.0), Vector3(45.3, -13.0, 0.0), 0)  # anchor
	await get_tree().process_frame
	await get_tree().process_frame
	# Folded small step INTO the radius (no check): 45.3 -> 44.9 (dist 2.9), within the window.
	rs.on_player_moved(1, "Ruin", Vector3(45.3, -13.0, 0.0), Vector3(44.9, -13.0, 0.0), 100)
	fm.credited.clear()
	# Post-window step whose OWN old_pos (44.9) is already inside; anchor (45.3) is outside -> credit.
	rs.on_player_moved(1, "Ruin", Vector3(44.9, -13.0, 0.0), Vector3(44.7, -13.0, 0.0), 300)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(
		"loc_old_well" in fm.credited, "crossing judged vs the anchor, never lost to sampling"
	)


func test_no_edge_no_credit() -> void:
	# Standing still well outside every radius must never credit — the throttle must not INVENT an
	# edge (regression guard for the anchor bookkeeping).
	var fm = FakeMaster.new()
	var rs = _service(fm)
	for i in range(10):
		rs.on_player_moved(
			1, "Ruin", Vector3(500.0, 500.0, 0.0), Vector3(500.0, 500.0, 0.0), i * 300
		)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(fm.credited, [], "no crossing edge -> no reach credit, ever")


func test_forget_clears_the_checkpoint() -> void:
	var fm = FakeMaster.new()
	var rs = _service(fm)
	rs.on_player_moved(1, "Ruin", Vector3(0.0, 0.0, 0.0), Vector3(20.0, 0.0, 0.0), 0)
	rs.forget(1)
	fm.credited.clear()
	# After forget, the next move is a "first move" again — checked immediately (fresh session).
	rs.on_player_moved(1, "Ruin", Vector3(38.0, -13.0, 0.0), WELL, 50)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true("loc_old_well" in fm.credited, "forget resets to first-move-checked behaviour")
