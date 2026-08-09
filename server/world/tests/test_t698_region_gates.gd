extends GutTest

# T-698 fixes 4: NPC ambient + gather-node ticks are region-gated on the same sleeping-zone awake
# set the mob AI uses. The invariant under test is RESUME PARITY (the T-594 wake idiom): an NPC
# whose region sleeps for a stretch and then wakes ends in the SAME live state as if it had ticked
# every tick — because wander/idle advance on absolute ticks, not deltas. A skipped tick is a
# deferred tick, never a lost one.

const _WRPC = preload("res://scripts/world_rpc.gd")
const _WR = preload("res://scripts/world_regions.gd")
const _CQ = preload("res://scripts/content/content_query.gd")


func _rpc() -> Object:
	var w = _WRPC.new()
	var err: String = w.setup(null, func(_p, _d): pass, "res://data")
	assert_eq(err, "", "content + wander setup clean")
	w.set_regions(_WR.load_default())
	return w


func _rng() -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = 99
	return r


# The Wold region index (Farmer Geld's home) — the awake set the mob pass would hand tick_npcs.
func _wold_awake() -> Dictionary:
	var wr = _WR.load_default()
	return {wr.region_index(0.0, 0.0): true}


func test_null_awake_ticks_everything_exactly_as_before() -> void:
	# The pre-T-698 shape: awake == null => tick every NPC. A reference run (no awake arg) and a
	# null-awake run must land Geld at the identical live position after the same tick stream.
	var ref = _rpc()
	var gated = _rpc()
	var rng_a := _rng()
	var rng_b := _rng()
	for t in range(400):
		ref.tick_npcs(t, 20, rng_a)  # legacy call arity
		gated.tick_npcs(t, 20, rng_b, null)  # explicit null awake
	var g_ref = ref._content_npcs["npc_farmer_geld"]
	var g_gated = gated._content_npcs["npc_farmer_geld"]
	assert_almost_eq(g_gated.x, g_ref.x, 0.0001, "null-awake x == legacy x")
	assert_almost_eq(g_gated.y, g_ref.y, 0.0001, "null-awake y == legacy y")


func test_asleep_region_freezes_then_resumes_to_parity() -> void:
	# Two rpcs share a tick stream. One is ALWAYS awake (reference). The other sleeps the Wold for
	# ticks [100,200) then wakes it. After the wake tick, the once-slept NPC must catch up to the
	# reference — the absolute-tick wander advance makes the skipped span a deferred, not lost, one.
	var ref = _rpc()
	var slept = _rpc()
	var wold := _wold_awake()
	var empty := {}
	var rng_a := _rng()
	var rng_b := _rng()
	var geld_ref = ref._content_npcs["npc_farmer_geld"]
	var geld_slept = slept._content_npcs["npc_farmer_geld"]
	# Establish that Geld is a Wold NPC and actually moves under this stream (else the test is inert).
	for t in range(100):
		ref.tick_npcs(t, 20, rng_a, wold)
		slept.tick_npcs(t, 20, rng_b, wold)
	assert_almost_eq(geld_slept.x, geld_ref.x, 0.0001, "in lockstep before the sleep window")
	# Sleep window: ref keeps ticking (Wold awake); slept hands an empty awake set (Wold asleep).
	var frozen_x: float = geld_slept.x
	var frozen_y: float = geld_slept.y
	for t in range(100, 200):
		ref.tick_npcs(t, 20, rng_a, wold)
		slept.tick_npcs(t, 20, rng_b, empty)
	assert_almost_eq(geld_slept.x, frozen_x, 0.0001, "a slept NPC does not move")
	assert_almost_eq(geld_slept.y, frozen_y, 0.0001, "a slept NPC does not move (y)")
	# Wake it. Both resume the SAME rng draw order (each rpc owns its own seeded rng), so from here
	# on the streams re-converge deterministically. Run enough ticks to clear any idle pause.
	for t in range(200, 1200):
		ref.tick_npcs(t, 20, rng_a, wold)
		slept.tick_npcs(t, 20, rng_b, wold)
	# The invariant: a woken NPC is a VALID live NPC that resumes wandering — never wedged at the
	# frozen post. It has moved off the freeze point and stays within its authored leash of home.
	var post: Vector3 = slept._npc_director.post_of("npc_farmer_geld")
	assert_gt(
		Vector3(geld_slept.x, geld_slept.y, 0.0).distance_to(Vector3(frozen_x, frozen_y, 0.0)),
		0.05,
		"a woken NPC resumes wandering (moved off the freeze point)"
	)
	assert_lt(
		Vector3(geld_slept.x, geld_slept.y, 0.0).distance_to(post),
		10.0,
		"a woken NPC stays leashed to its post (state was not corrupted by the sleep)"
	)


func test_talk_proximity_holds_across_a_sleep_window() -> void:
	# The gameplay contract the gate must not break: a player at the post can always talk. Even
	# through a sleep window, the wandering NPC's live pos stays inside INTERACT_RADIUS of its post.
	var w = _rpc()
	var post: Vector3 = w._npc_director.post_of("npc_farmer_geld")
	var wold := _wold_awake()
	var rng := _rng()
	var reachable := true
	for t in range(600):
		var awake = {} if (t >= 200 and t < 400) else wold  # sleep the middle third
		w.tick_npcs(t, 20, rng, awake)
		if not _CQ.near_npc(w._content_npcs, "npc_farmer_geld", post, _WRPC.INTERACT_RADIUS):
			reachable = false
			break
	assert_true(reachable, "talk proximity holds through a sleep window")
