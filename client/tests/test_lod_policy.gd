extends GutTest

# T-120: pure LodPolicy distance thresholds + impostor hysteresis. No rendering context, no OS
# time — the same isolation as test_npc_wander / test_critter_wander. The in-world FPS/visual
# proof is DEFERRED to the orchestrator's qa-tour; these lock the swap MATH.

const LodPolicy = preload("res://scripts/world/lod_policy.gd")

# ---- cull_distance ----


func test_cull_distance_class_table() -> void:
	assert_almost_eq(LodPolicy.cull_distance("furn_stool.glb"), 160.0, 0.01, "furniture near cull")
	assert_almost_eq(LodPolicy.cull_distance("prop_bush_a.glb"), 160.0, 0.01, "bush near cull")
	assert_almost_eq(LodPolicy.cull_distance("prop_rock_b.glb"), 220.0, 0.01, "rock mid cull")
	assert_almost_eq(LodPolicy.cull_distance("prop_stump.glb"), 220.0, 0.01, "stump mid cull")
	assert_almost_eq(LodPolicy.cull_distance("prop_sapling_pine.glb"), 240.0, 0.01, "sapling far")


func test_buildings_never_cull() -> void:
	assert_eq(LodPolicy.cull_distance("prop_inn.glb"), 0.0, "inn never culls (silhouette)")
	assert_eq(LodPolicy.cull_distance("prop_hk_walls.glb"), 0.0, "city wall never culls")
	assert_eq(LodPolicy.cull_distance("prop_barn.glb"), 0.0, "barn never culls")


func test_trees_get_generous_cull_not_the_default_zero() -> void:
	# Trees impostor, so they carry a long cull range (the billboard is cheap out there).
	assert_almost_eq(LodPolicy.cull_distance("prop_oak_real.glb"), 320.0, 0.01, "tree cull 320")
	assert_almost_eq(LodPolicy.cull_distance("prop_tree_fir_a.glb"), 320.0, 0.01, "fir cull 320")


# ---- impostor_distance / class membership ----


func test_impostor_distance_trees_only() -> void:
	assert_almost_eq(LodPolicy.impostor_distance("prop_oak_real.glb"), 90.0, 0.01, "oak impostors")
	assert_almost_eq(LodPolicy.impostor_distance("prop_pine_c.glb"), 90.0, 0.01, "pine impostors")
	assert_eq(LodPolicy.impostor_distance("prop_inn.glb"), 0.0, "buildings have no impostor")
	assert_eq(LodPolicy.impostor_distance("prop_rock_a.glb"), 0.0, "rocks have no impostor")


func test_impostor_texture_path_convention() -> void:
	assert_eq(
		LodPolicy.impostor_texture_path("res://assets/models/prop_oak_real.glb"),
		"res://assets/models/prop_oak_real_impostor.png",
		"impostor path = stem + _impostor.png"
	)
	assert_eq(
		LodPolicy.impostor_texture_path("res://assets/models/prop_inn.glb"),
		"",
		"non-impostor class -> empty path"
	)


# ---- T-692 Part B: the preset distance multiplier ----


func test_cull_distance_scales_linearly_with_the_preset_mult() -> void:
	assert_almost_eq(LodPolicy.cull_distance("prop_rock_b.glb", 0.55), 121.0, 0.01, "low rock")
	assert_almost_eq(LodPolicy.cull_distance("prop_bush_a.glb", 0.8), 128.0, 0.01, "medium bush")
	assert_almost_eq(LodPolicy.cull_distance("prop_oak_real.glb", 1.25), 400.0, 0.01, "ultra tree")
	assert_almost_eq(
		LodPolicy.cull_distance("prop_rock_b.glb"), 220.0, 0.01, "default mult = the baseline"
	)


func test_never_cull_classes_stay_uncullable_at_every_mult() -> void:
	assert_eq(LodPolicy.cull_distance("prop_inn.glb", 0.55), 0.0, "buildings never cull on Low")
	assert_eq(LodPolicy.cull_distance("prop_hk_walls.glb", 1.25), 0.0, "walls never cull on Ultra")


func test_impostor_distance_scales_with_the_preset_mult() -> void:
	assert_almost_eq(LodPolicy.impostor_distance("prop_oak_real.glb", 0.55), 49.5, 0.01, "low oak")
	assert_almost_eq(
		LodPolicy.impostor_distance("prop_pine_c.glb", 1.25), 112.5, 0.01, "ultra pine"
	)
	assert_eq(LodPolicy.impostor_distance("prop_inn.glb", 0.55), 0.0, "non-impostor class stays 0")


# ---- impostor_active hysteresis ----


func test_active_true_well_past_band() -> void:
	assert_true(LodPolicy.impostor_active(200.0, 90.0, 12.0, false), "far -> impostor")


func test_active_false_well_inside_band() -> void:
	assert_false(LodPolicy.impostor_active(10.0, 90.0, 12.0, true), "near -> real mesh")


func test_hysteresis_holds_previous_state_in_the_band() -> void:
	# 90 +/- 12 = [78, 102]. Inside the band the previous decision must hold (no flicker).
	assert_false(LodPolicy.impostor_active(95.0, 90.0, 12.0, false), "was mesh, stays mesh in band")
	assert_true(LodPolicy.impostor_active(95.0, 90.0, 12.0, true), "was impostor, stays in band")


func test_hysteresis_edges_are_decisive() -> void:
	assert_true(LodPolicy.impostor_active(102.0, 90.0, 12.0, false), "at upper edge -> impostor")
	assert_false(LodPolicy.impostor_active(78.0, 90.0, 12.0, true), "at lower edge -> mesh")


func test_no_impostor_class_is_always_mesh() -> void:
	# imp_dist <= 0 means "this class never impostors" regardless of distance/history.
	assert_false(LodPolicy.impostor_active(500.0, 0.0, 12.0, true), "imp_dist 0 -> never active")


func test_swap_is_monotonic_across_a_flyout() -> void:
	# Walk the camera out then back; the impostor turns on once and off once, no chatter.
	var active := false
	var switches := 0
	for d in [0.0, 40.0, 80.0, 100.0, 120.0, 200.0, 120.0, 100.0, 80.0, 40.0, 0.0]:
		var nxt := LodPolicy.impostor_active(float(d), 90.0, 12.0, active)
		if nxt != active:
			switches += 1
		active = nxt
	assert_eq(switches, 2, "exactly one on and one off over the round trip")
	assert_false(active, "back at the tree -> real mesh")


# ---- clutter cull (T-758) ----


func test_clutter_cull_distance_by_class() -> void:
	# The boot-scatter ground clutter (WorldView) routes through here; each class has a positive
	# cull comfortably beyond its scatter radius so the near field never clips.
	assert_almost_eq(LodPolicy.clutter_cull_distance("grass"), 150.0, 0.01, "grass tufts cull")
	assert_almost_eq(LodPolicy.clutter_cull_distance("rock"), 200.0, 0.01, "scatter rocks cull")
	assert_almost_eq(LodPolicy.clutter_cull_distance("flower"), 160.0, 0.01, "meadow flowers cull")


func test_clutter_cull_unknown_class_is_uncapped() -> void:
	assert_eq(
		LodPolicy.clutter_cull_distance("not_a_class"),
		0.0,
		"unknown class leaves the pool uncapped"
	)


func test_clutter_cull_scales_with_the_preset_multiplier() -> void:
	assert_almost_eq(
		LodPolicy.clutter_cull_distance("grass", 0.5), 75.0, 0.01, "Low preset halves the range"
	)
