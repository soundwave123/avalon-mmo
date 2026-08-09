extends GutTest

# T-446: pure NpcSeparation pass — deterministic personal-space repulsion, no rng, no OS time,
# inputs never mutated. Converging NPCs separate; a same-footprint pair splits; far NPCs untouched.

const _NS = preload("res://scripts/npc_separation.gd")

const DT := 1.0 / 20.0
const MIN_DIST := 1.5
const STEP := 1.0 * DT  # SEP_SPEED * dt, the director's per-tick cap


func test_far_apart_npcs_are_untouched() -> void:
	var out: Dictionary = _NS.separate(
		{"a": Vector3(0, 0, 0), "b": Vector3(10, 0, 0)}, [], MIN_DIST, STEP
	)
	assert_eq(out["a"], Vector3(0, 0, 0), "no push outside min_dist")
	assert_eq(out["b"], Vector3(10, 0, 0), "no push outside min_dist")


func test_overlapping_pair_separates_to_min_dist() -> void:
	# Two NPCs 0.4 m apart (interpenetrating capsules) shuffle apart over ticks until spaced.
	var pos := {"a": Vector3(0, 0, 0), "b": Vector3(0.4, 0, 0)}
	for _t in range(200):
		pos = _NS.separate(pos, [], MIN_DIST, STEP)
	var d: float = (pos["a"] as Vector3).distance_to(pos["b"])
	assert_gt(d, MIN_DIST - 0.01, "stationary neighbours end up personal-space apart")


func test_same_footprint_pair_splits_deterministically() -> void:
	# The audit clump: two NPCs on the EXACT same spot still separate (id-hash direction, no rng).
	var pos := {"hale": Vector3(5, 5, 0), "loreth": Vector3(5, 5, 0)}
	for _t in range(300):
		pos = _NS.separate(pos, [], MIN_DIST, STEP)
	assert_gt(
		(pos["hale"] as Vector3).distance_to(pos["loreth"]),
		MIN_DIST - 0.01,
		"coincident NPCs split apart"
	)


func test_three_way_clump_all_spaced() -> void:
	var pos := {"a": Vector3(0, 0, 0), "b": Vector3(0.3, 0.1, 0), "c": Vector3(0.1, 0.3, 0)}
	for _t in range(400):
		pos = _NS.separate(pos, [], MIN_DIST, STEP)
	for i in ["a", "b", "c"]:
		for j in ["a", "b", "c"]:
			if i < j:
				assert_gt(
					(pos[i] as Vector3).distance_to(pos[j]),
					MIN_DIST - 0.05,
					"%s/%s spaced" % [i, j]
				)


func test_fixed_obstacle_pushes_mover_but_never_moves() -> void:
	var fixed := [Vector3(0.5, 0, 0)]
	var pos := {"a": Vector3(0, 0, 0)}
	for _t in range(200):
		pos = _NS.separate(pos, fixed, MIN_DIST, STEP)
	assert_gt(
		(pos["a"] as Vector3).distance_to(fixed[0]),
		MIN_DIST - 0.01,
		"mover pushed off the rooted NPC"
	)


func test_push_is_capped_at_max_step_per_call() -> void:
	var out: Dictionary = _NS.separate(
		{"a": Vector3(0, 0, 0), "b": Vector3(0.01, 0, 0)}, [], MIN_DIST, STEP
	)
	var moved: float = (out["a"] as Vector3).length()
	assert_lt(moved, STEP + 0.0001, "one pass never shoves farther than max_step (no teleports)")


func test_separate_is_pure_and_deterministic() -> void:
	var pos := {"a": Vector3(0, 0, 0), "b": Vector3(0.4, 0.2, 0)}
	var before := pos.duplicate(true)
	var out1: Dictionary = _NS.separate(pos, [], MIN_DIST, STEP)
	var out2: Dictionary = _NS.separate(pos, [], MIN_DIST, STEP)
	assert_eq(pos, before, "input positions never mutated")
	assert_eq(out1, out2, "same input, same output — fully deterministic")


func test_clamp_to_post_leashes_a_shoved_npc() -> void:
	var post := Vector3(5, 2, 0)
	assert_eq(
		_NS.clamp_to_post(Vector3(5.5, 2, 0), post, 2.0),
		Vector3(5.5, 2, 0),
		"inside the leash = untouched"
	)
	var clamped: Vector3 = _NS.clamp_to_post(Vector3(9, 2, 0), post, 2.0)
	assert_almost_eq(clamped.distance_to(post), 2.0, 0.0001, "outside snaps back onto the leash")
