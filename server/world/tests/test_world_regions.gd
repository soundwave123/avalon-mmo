extends GutTest

# T-590: the zone-origin / terrain-region layer. Proves (a) the shipped table is EXACTLY today's
# world, (b) the clamp is byte-identical to the pre-T-590 flat ±500 box for both regions, (c) the
# per-region respawn anchors match the old hardcodes, (d) a NEW toy region proves the clamp +
# respawn generalize, and (e) the terrain-side const mirror + AOI membership anchors stay in sync.

const _WR = preload("res://scripts/world_regions.gd")
const _BB = preload("res://scripts/broadcast_builder.gd")
const _TF = preload("res://scripts/terrain_field.gd")
const _MCOL = preload("res://scripts/movement_collision.gd")
const _MRL = preload("res://scripts/move_rate_limiter.gd")


# ---- (a) the shipped table is today's world -------------------------------------------------
func test_default_table_seeds_the_three_p1_regions() -> void:
	# T-593 authored the three phase-1 regions: Heartwold (Wold, era 1), Ashmoor City (era 2), and
	# the NEW Greyrise Reach (era 3) at its far origin.
	var wr = _WR.load_default()
	assert_eq(wr.region_count(), 3, "three P1 regions ship after T-593")
	assert_eq(wr.region_id_at(0.0, 0.0), "wold", "origin is the Wold / Heartwold")
	assert_eq(wr.region_id_at(-420.0, 0.0), "ashmoor", "the west offset is Ashmoor City")
	assert_eq(wr.region_id_at(0.0, -1400.0), "greyrise", "the far south origin is Greyrise Reach")
	assert_eq(wr.era_at(0.0, 0.0), 1, "the Wold is era 1")
	assert_eq(wr.era_at(-420.0, 0.0), 2, "Ashmoor is era 2")
	assert_eq(wr.era_at(0.0, -1400.0), 3, "Greyrise is era 3")


func test_region_index_uses_nearest_origin() -> void:
	# The T-371 nearest-anchor split: the wold/ashmoor boundary falls at x = -210.
	var wr = _WR.load_default()
	assert_eq(wr.region_id_at(-209.0, 0.0), "wold", "just east of the seam is the Wold")
	assert_eq(wr.region_id_at(-211.0, 0.0), "ashmoor", "just west of the seam is Ashmoor")


# ---- (b) T-593 raised each region to its own P1 envelope ------------------------------------
func test_clamp_honours_each_regions_p1_envelope() -> void:
	# T-593 clamp raise: Heartwold ±620 m, Ashmoor City ±550 m centred on (-420,0), Greyrise Reach
	# ±560 m centred on (0,-1400). Movement + spawn validation read these per-region boxes.
	var wr = _WR.load_default()
	# Heartwold ±620 (grown from the old ±500 toward the mountain rim).
	assert_eq(wr.clamp_xz(700.0, 0.0), Vector2(620.0, 0.0), "Heartwold east edge clamps at +620")
	assert_eq(wr.clamp_xz(0.0, 900.0), Vector2(0.0, 620.0), "Heartwold z clamps at +620")
	assert_true(wr.in_bounds(619.0, 0.0), "just inside the Heartwold envelope is in bounds")
	assert_false(wr.in_bounds(700.0, 0.0), "past +620 in the Wold is out of bounds")
	# Ashmoor City ±550 centred on (-420,0): x in [-970, 130], z in [-550, 550].
	assert_eq(wr.clamp_xz(-1000.0, 0.0), Vector2(-970.0, 0.0), "Ashmoor west edge clamps at -970")
	assert_eq(wr.clamp_xz(-420.0, 700.0), Vector2(-420.0, 550.0), "Ashmoor z clamps at +550")
	assert_true(wr.in_bounds(-960.0, 0.0), "inside the raised Ashmoor envelope is in bounds")
	assert_false(wr.in_bounds(-980.0, 0.0), "past -970 in Ashmoor is out of bounds")
	# Greyrise Reach ±560 centred on (0,-1400): x in [-560, 560], z in [-1960, -840].
	assert_eq(
		wr.clamp_xz(0.0, -2000.0), Vector2(0.0, -1960.0), "Greyrise south edge clamps at -1960"
	)
	assert_eq(
		wr.clamp_xz(700.0, -1400.0), Vector2(560.0, -1400.0), "Greyrise east edge clamps at +560"
	)
	assert_true(wr.in_bounds(0.0, -1400.0), "the Greyrise origin is in bounds")
	assert_false(wr.in_bounds(9000.0, 0.0), "far outside every envelope is rejected")


func test_movement_collision_clamps_through_the_region_table() -> void:
	# The live wiring: movement_collision loads regions.json and routes its clamp through it. A
	# rate-legal hop leaving the RAISED Ashmoor envelope clamps at -970 (not rejected), proving the
	# clamp raise took effect end-to-end with no code change.
	var c = _MCOL.new()  # loads barriers + regions.json
	var res: Dictionary = c.resolve(Vector2(-940.0, 0.0), Vector2(-60.0, 0.0), 7, 0, _MRL.new())
	assert_true(res["ok"], "an out-of-bounds move is clamped, not rejected")
	assert_almost_eq(res["pos"].x, -970.0, 0.01, "clamped to the raised Ashmoor envelope (-970)")


# ---- (c) per-region respawn anchors match the old hardcodes ---------------------------------
func test_respawn_anchor_per_region_matches_legacy() -> void:
	var wr = _WR.load_default()
	assert_eq(
		wr.respawn_at(10.0, -30.0), Vector2(0.0, 0.0), "a Wold death respawns at world origin"
	)
	assert_eq(
		wr.respawn_at(-420.0, -5.0),
		Vector2(-432.0, -14.0),
		"an Ashmoor death -> the pauper's field"
	)


# ---- (d) a NEW toy region proves the mechanism generalizes ----------------------------------
func _toy_doc() -> Dictionary:
	return {
		"global_clamp": {"min": [-500.0, -500.0], "max": [500.0, 500.0]},
		"regions":
		[
			{
				"region_id": "wold",
				"era": 1,
				"origin": [0.0, 0.0],
				"respawn": [0.0, 0.0],
				"clamp": null
			},
			{
				"region_id": "toy",
				"era": 9,
				"origin": [0.0, -900.0],
				"respawn": [5.0, -905.0],
				"clamp": {"min": [-60.0, -960.0], "max": [60.0, -840.0]},
			},
		],
	}


func test_toy_region_clamp_honours_its_own_extent() -> void:
	var wr = _WR.new(_toy_doc())
	# Near the toy origin the clamp is the toy's tighter envelope, NOT the global box.
	assert_eq(wr.region_id_at(0.0, -900.0), "toy", "dispatches to the toy region")
	assert_eq(wr.clamp_xz(200.0, -900.0), Vector2(60.0, -900.0), "toy clamps x at its own +60")
	assert_eq(wr.clamp_xz(0.0, -700.0), Vector2(0.0, -840.0), "toy clamps z at its own -840")
	assert_false(wr.in_bounds(100.0, -900.0), "outside the toy envelope is out of bounds")
	# The Wold half of the same table still uses the global box (regions are independent).
	assert_eq(
		wr.clamp_xz(600.0, 0.0), Vector2(500.0, 0.0), "the Wold still clamps at the global 500"
	)


func test_toy_region_respawn_anchors_to_it() -> void:
	var wr = _WR.new(_toy_doc())
	assert_eq(
		wr.respawn_at(0.0, -900.0), Vector2(5.0, -905.0), "a death in the toy region respawns in it"
	)
	assert_eq(
		wr.respawn_at(0.0, 0.0), Vector2(0.0, 0.0), "a Wold death is unaffected by the toy region"
	)


# ---- (e) the terrain-side const mirror + AOI membership anchors stay in sync ----------------
func test_terrain_field_origins_mirror_the_table() -> void:
	# terrain_field.gd holds a const mirror of the region origins (it is shared/pure and can't load
	# the server-only JSON). Assert the two agree so the mirror can never silently drift.
	var wr = _WR.load_default()
	var tf = _TF.new()
	var tf_origins: Array = tf.region_origins()
	assert_eq(tf_origins.size(), wr.region_count(), "same region count on both sides")
	for i in wr.region_count():
		assert_true(
			tf_origins.has(wr.origin_of(i)),
			"terrain mirror is missing region origin %s" % wr.origin_of(i)
		)


func test_every_region_origin_is_an_aoi_membership_anchor() -> void:
	# Every terrain zone must also be an AOI/region-bucketing anchor (broadcast_builder.REGION_ANCHORS)
	# so entities in a zone are scoped to that zone's broadcast domain.
	var wr = _WR.load_default()
	var anchors: Array = _BB.REGION_ANCHORS
	for i in wr.region_count():
		assert_true(
			anchors.has(wr.origin_of(i)), "region origin %s is not an AOI anchor" % wr.origin_of(i)
		)
