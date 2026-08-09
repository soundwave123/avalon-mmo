extends "res://addons/gut/test.gd"

# T-594: the pure prop-streaming policy. Proves classification (hero/building/flora + tag override),
# nearest-origin region membership, the region + distance-ring residency decision, DETERMINISM (the
# resident set is a pure function of player position), and that plan() is a clean set-difference,
# no duplicate load/unload.

const PropStreamer = preload("res://scripts/world/prop_streamer.gd")

const ORIGINS := [Vector2(0.0, 0.0), Vector2(-420.0, 0.0), Vector2(0.0, -1400.0)]


func _meta(i: int, ground: Vector2, tier: int, region: int) -> Dictionary:
	return {"i": i, "ground": ground, "tier": tier, "region": region, "streamable": true}


# ---- classification -------------------------------------------------------------------------
func test_classify_sorts_props_into_draw_tiers() -> void:
	assert_eq(PropStreamer.classify("prop_hk_keep_main.glb", ""), PropStreamer.TIER_HERO)
	assert_eq(PropStreamer.classify("prop_cottage_v2.glb", ""), PropStreamer.TIER_BUILDING)
	assert_eq(PropStreamer.classify("prop_farmhouse.glb", ""), PropStreamer.TIER_BUILDING)
	assert_eq(PropStreamer.classify("prop_oak_real.glb", ""), PropStreamer.TIER_FLORA)
	assert_eq(PropStreamer.classify("prop_flora_dock.glb", ""), PropStreamer.TIER_FLORA)


func test_hub_tag_overrides_the_mesh_into_a_resident_landmark() -> void:
	# An authored hub prop stays resident even if its mesh looks like flora.
	assert_eq(PropStreamer.classify("prop_fern.glb", "rift"), PropStreamer.TIER_HERO)
	assert_eq(PropStreamer.classify("prop_barrel.glb", "highkeep"), PropStreamer.TIER_HERO)


# ---- region membership ----------------------------------------------------------------------
func test_region_of_uses_nearest_origin() -> void:
	assert_eq(
		PropStreamer.region_of(Vector2(10.0, 10.0), ORIGINS), 0, "near the origin is the Wold"
	)
	assert_eq(
		PropStreamer.region_of(Vector2(-440.0, 20.0), ORIGINS), 1, "the west offset is Ashmoor"
	)
	assert_eq(
		PropStreamer.region_of(Vector2(0.0, -1400.0), ORIGINS), 2, "the far south is Greyrise"
	)
	assert_eq(PropStreamer.region_of(Vector2(0.0, 0.0), []), -1, "an empty table yields -1")


# ---- region residency: other-region props never load ----------------------------------------
func test_other_region_props_are_never_resident() -> void:
	var metas := [
		_meta(0, Vector2(10.0, 0.0), PropStreamer.TIER_FLORA, 0),  # Wold flora, near
		_meta(1, Vector2(-440.0, 0.0), PropStreamer.TIER_BUILDING, 1),  # Ashmoor building
	]
	# Player in the Wold (region 0): only the Wold prop is resident; the Ashmoor prop is dropped whole.
	var target := PropStreamer.resident_target(metas, Vector2(0.0, 0.0), 0, {})
	assert_true(target.has(0), "the in-region prop is resident")
	assert_false(target.has(1), "the other-region prop never instantiates")


# ---- distance ring: flora carpet streams, hero/building stay ---------------------------------
func test_distance_ring_gates_flora_but_not_hero_or_building() -> void:
	var cfg := {"flora_ring": 100.0, "building_ring": 500.0}
	var metas := [
		_meta(0, Vector2(50.0, 0.0), PropStreamer.TIER_FLORA, 0),  # flora inside ring
		_meta(1, Vector2(300.0, 0.0), PropStreamer.TIER_FLORA, 0),  # flora outside ring
		_meta(2, Vector2(300.0, 0.0), PropStreamer.TIER_BUILDING, 0),  # building inside its ring
		_meta(3, Vector2(9000.0, 0.0), PropStreamer.TIER_HERO, 0),  # hero: unbounded within region
	]
	var target := PropStreamer.resident_target(metas, Vector2(0.0, 0.0), 0, cfg)
	assert_true(target.has(0), "flora inside the ring is resident")
	assert_false(target.has(1), "flora beyond the ring streams out")
	assert_true(target.has(2), "a building within its larger ring stays resident")
	assert_true(target.has(3), "a hero landmark is resident regardless of distance")


# ---- determinism: same position -> same set, walk-and-return is identical ---------------------
func test_resident_set_is_a_pure_function_of_position() -> void:
	var cfg := {"flora_ring": 100.0}
	var metas := [
		_meta(0, Vector2(0.0, 0.0), PropStreamer.TIER_FLORA, 0),
		_meta(1, Vector2(0.0, 250.0), PropStreamer.TIER_FLORA, 0),
	]
	var here := Vector2(0.0, 0.0)
	var there := Vector2(0.0, 250.0)
	# Ten border crossings: the resident set at each standpoint is byte-identical every time.
	var first_here: Array = PropStreamer.resident_target(metas, here, 0, cfg).keys()
	var first_there: Array = PropStreamer.resident_target(metas, there, 0, cfg).keys()
	first_here.sort()
	first_there.sort()
	for _n in range(10):
		var h: Array = PropStreamer.resident_target(metas, here, 0, cfg).keys()
		var t: Array = PropStreamer.resident_target(metas, there, 0, cfg).keys()
		h.sort()
		t.sort()
		assert_eq(h, first_here, "the resident set at 'here' is identical on every visit")
		assert_eq(t, first_there, "the resident set at 'there' is identical on every visit")
	assert_eq(first_here, [0], "only the near flora is resident at the origin")
	assert_eq(first_there, [1], "only the far flora is resident at the far standpoint")


# ---- plan: clean set difference, no duplicate load/unload ------------------------------------
func test_plan_is_a_clean_set_difference() -> void:
	var current := {1: true, 2: true}
	var target := {2: true, 3: true}
	var p := PropStreamer.plan(current, target)
	assert_eq(p["load"], [3], "only the newly wanted index loads")
	assert_eq(p["unload"], [1], "only the no-longer-wanted index unloads")
	# The overlap (2) is neither loaded nor unloaded — never double-touched.
	assert_false((p["load"] as Array).has(2))
	assert_false((p["unload"] as Array).has(2))


func test_plan_no_change_is_empty() -> void:
	var same := {5: true, 6: true}
	var p := PropStreamer.plan(same, same)
	assert_eq(p["load"], [], "no loads when the set is unchanged")
	assert_eq(p["unload"], [], "no unloads when the set is unchanged")


func test_flora_streamable_excludes_critters() -> void:
	var critters := {"mob_sheep.glb": true}
	assert_true(PropStreamer.flora_streamable("prop_oak_real.glb", critters), "a tree streams")
	assert_false(
		PropStreamer.flora_streamable("mob_sheep.glb", critters), "livestock stays resident"
	)


# ---- T-692 Part B: preset cfg readers + deterministic flora-density thinning ------------------
func test_cfg_readers_default_to_the_authored_baseline() -> void:
	assert_almost_eq(PropStreamer.lod_mult({}), 1.0, 0.001, "no cfg -> mult 1")
	assert_almost_eq(PropStreamer.lod_mult({"lod_mult": 0.55}), 0.55, 0.001, "cfg mult reads back")
	assert_almost_eq(PropStreamer.flora_density({}), 1.0, 0.001, "no cfg -> full density")
	assert_almost_eq(
		PropStreamer.flora_density({"flora_density": 2.0}), 1.0, 0.001, "density clamps to [0, 1]"
	)


func test_density_kept_is_exact_and_deterministic_over_a_full_bucket() -> void:
	# (index * K) % 1000 is a bijection over any 1000 consecutive indices (gcd(K, 1000) = 1), so
	# the kept count is EXACTLY density * 1000 — the exact deterministic subsample per tier.
	for density: float in [0.5, 0.75]:
		var kept := 0
		for i in 1000:
			if PropStreamer.density_kept(i, density):
				kept += 1
		assert_eq(kept, int(density * 1000.0), "density %s keeps exactly its fraction" % density)


func test_density_kept_edges_and_monotonicity_across_tiers() -> void:
	for i in 200:
		assert_true(PropStreamer.density_kept(i, 1.0), "density 1 keeps everything")
		assert_false(PropStreamer.density_kept(i, 0.0), "density 0 keeps nothing")
		if PropStreamer.density_kept(i, 0.5):
			assert_true(
				PropStreamer.density_kept(i, 0.75), "raising the tier only ADDS flora (monotone)"
			)


func test_density_drops_spares_buildings_hero_and_special_bases() -> void:
	var special := {"prop_lamppost_v2.glb": true, "mob_sheep.glb": true}
	var cfg := {"flora_density": 0.0}  # even at drop-everything…
	assert_false(
		PropStreamer.density_drops(
			PropStreamer.TIER_BUILDING, "prop_cottage_v2.glb", 3, cfg, special
		),
		"buildings never thin (silhouette = navigation)"
	)
	assert_false(
		PropStreamer.density_drops(PropStreamer.TIER_HERO, "prop_rift.glb", 3, cfg, special),
		"hero landmarks never thin"
	)
	assert_false(
		PropStreamer.density_drops(
			PropStreamer.TIER_FLORA, "prop_lamppost_v2.glb", 3, cfg, special
		),
		"special bases (night-lights/critters) never thin"
	)
	assert_true(
		PropStreamer.density_drops(PropStreamer.TIER_FLORA, "prop_fern.glb", 3, cfg, special),
		"plain flora thins by the preset density"
	)


func test_lower_tier_ring_target_is_a_subset_of_the_higher_tier_ring() -> void:
	# The Low preset's flora ring (190) must resolve to a strict subset of High's (340) — the
	# preset only shrinks the resident carpet, it never swaps it for a different one.
	var metas: Array = []
	for i in 40:
		metas.append(_meta(i, Vector2(float(i) * 10.0, 0.0), PropStreamer.TIER_FLORA, 0))
	var low: Dictionary = PropStreamer.resident_target(
		metas, Vector2.ZERO, 0, {"flora_ring": 190.0}
	)
	var high: Dictionary = PropStreamer.resident_target(
		metas, Vector2.ZERO, 0, {"flora_ring": 340.0}
	)
	assert_true(low.size() < high.size(), "the low ring keeps strictly fewer flora resident")
	for i in low:
		assert_true(high.has(i), "every Low-resident prop is also High-resident (ring subset)")


# ---- T-693: the name-level batchable predicate ------------------------------------------------
func test_batchable_stem_is_flora_only_minus_special_bases() -> void:
	var special := {"mob_sheep.glb": true, "prop_lamppost_v2.glb": true}
	assert_true(
		PropStreamer.batchable_stem("prop_rock_a.glb", "", special), "repeated flora may batch"
	)
	assert_false(
		PropStreamer.batchable_stem("prop_cottage_v2.glb", "", special), "buildings never batch"
	)
	assert_false(
		PropStreamer.batchable_stem("prop_hk_keep_main.glb", "", special), "hero stems never batch"
	)
	assert_false(
		PropStreamer.batchable_stem("prop_fern.glb", "rift", special),
		"a hub tag promotes out of the batch tier"
	)
	assert_false(
		PropStreamer.batchable_stem("prop_lamppost_v2.glb", "", special),
		"engine-attached night-light bases stay individual"
	)
	assert_false(
		PropStreamer.batchable_stem("mob_sheep.glb", "", special), "critters stay individual"
	)
