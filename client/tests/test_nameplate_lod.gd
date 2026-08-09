extends GutTest

# T-463: pure nameplate LOD + declutter math (distance fade band, bunched-crowd vertical stagger).

const NameplateLod = preload("res://scripts/ui/nameplate_lod.gd")


func test_fully_readable_inside_fade_start() -> void:
	assert_eq(NameplateLod.alpha_for_distance(0.0), 1.0)
	assert_eq(NameplateLod.alpha_for_distance(NameplateLod.FADE_START), 1.0)


func test_gone_past_fade_end() -> void:
	assert_eq(NameplateLod.alpha_for_distance(NameplateLod.FADE_END), 0.0)
	assert_eq(NameplateLod.alpha_for_distance(999.0), 0.0, "never negative at extreme range")


func test_linear_falloff_across_the_band() -> void:
	var mid := (NameplateLod.FADE_START + NameplateLod.FADE_END) / 2.0
	assert_almost_eq(NameplateLod.alpha_for_distance(mid), 0.5, 0.001, "band midpoint reads half")


func test_custom_band_is_respected() -> void:
	assert_eq(NameplateLod.alpha_for_distance(5.0, 10.0, 20.0), 1.0)
	assert_almost_eq(NameplateLod.alpha_for_distance(15.0, 10.0, 20.0), 0.5, 0.001)
	assert_eq(NameplateLod.alpha_for_distance(25.0, 10.0, 20.0), 0.0)


func test_spread_out_units_get_no_stagger() -> void:
	var anchors := [Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(0, 0, 10)]
	assert_eq(NameplateLod.stagger_offsets(anchors), [0.0, 0.0, 0.0], "far apart -> all at rest")


func test_bunched_units_stack_into_a_column() -> void:
	# Four NPCs bunched inside the cluster radius (the training-yard smear): each later plate
	# lifts one more step, so all four heights are DISTINCT — no two names overlap.
	var anchors := [
		Vector3(0, 0, 0), Vector3(0.5, 0, 0), Vector3(0.0, 0, 0.5), Vector3(0.5, 0, 0.5)
	]
	var offs := NameplateLod.stagger_offsets(anchors)
	var s := NameplateLod.STAGGER_STEP
	assert_eq(offs, [0.0, s, s * 2.0, s * 3.0], "each bunched plate rises one more step")


func test_stagger_ignores_height_differences() -> void:
	# Clustering is planar (x/z) — a flying/elevated anchor over the same spot still stacks.
	var anchors := [Vector3(0, 0, 0), Vector3(0.2, 5.0, 0.2)]
	var offs := NameplateLod.stagger_offsets(anchors)
	assert_eq(offs[1], NameplateLod.STAGGER_STEP, "y difference does not defeat the declutter")


func test_two_separate_bunches_stagger_independently() -> void:
	var anchors := [Vector3(0, 0, 0), Vector3(0.5, 0, 0), Vector3(50, 0, 0), Vector3(50.5, 0, 0)]
	var offs := NameplateLod.stagger_offsets(anchors)
	var s := NameplateLod.STAGGER_STEP
	assert_eq(offs, [0.0, s, 0.0, s], "a distant second bunch restarts its own column")


func test_stagger_is_deterministic_for_a_stable_order() -> void:
	var anchors := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0.5, 0, 0.5)]
	assert_eq(
		NameplateLod.stagger_offsets(anchors),
		NameplateLod.stagger_offsets(anchors),
		"same anchors, same offsets — no frame-to-frame flicker"
	)


# T-589: marker long-range tier — quest !/? are spottable well past where names/health have faded.
func test_marker_alpha_at_30m_is_visible() -> void:
	var a := NameplateLod.alpha_for_distance(
		30.0, NameplateLod.MARKER_FADE_START, NameplateLod.MARKER_FADE_END
	)
	assert_true(a > 0.0, "30 m is inside the marker's long-range tier (40-55 m fade band)")


func test_name_alpha_at_30m_is_still_gone() -> void:
	# Short tier (16-28 m) is unchanged by adding the marker tier.
	var a := NameplateLod.alpha_for_distance(30.0)
	assert_eq(a, 0.0, "30 m is past the unchanged 16-28 m name/health fade band")


func test_marker_fully_visible_inside_fade_start_gone_past_fade_end() -> void:
	assert_eq(
		NameplateLod.alpha_for_distance(
			35.0, NameplateLod.MARKER_FADE_START, NameplateLod.MARKER_FADE_END
		),
		1.0
	)
	assert_eq(
		NameplateLod.alpha_for_distance(
			60.0, NameplateLod.MARKER_FADE_START, NameplateLod.MARKER_FADE_END
		),
		0.0
	)


# T-589: scale-shrink curve.
func test_scale_full_size_close_up() -> void:
	assert_eq(NameplateLod.scale_for_distance(0.0), 1.0)
	assert_eq(NameplateLod.scale_for_distance(NameplateLod.SCALE_FULL_DISTANCE), 1.0)


func test_scale_floor_respected_at_and_past_the_fade_edge() -> void:
	assert_eq(NameplateLod.scale_for_distance(NameplateLod.FADE_END), NameplateLod.SCALE_FLOOR)
	assert_eq(
		NameplateLod.scale_for_distance(999.0),
		NameplateLod.SCALE_FLOOR,
		"never shrinks below the floor at extreme range"
	)


func test_scale_shrinks_between_full_and_floor() -> void:
	var mid := (NameplateLod.SCALE_FULL_DISTANCE + NameplateLod.FADE_END) / 2.0
	var s := NameplateLod.scale_for_distance(mid)
	assert_true(
		s < 1.0 and s > NameplateLod.SCALE_FLOOR, "midpoint sits strictly between full and floor"
	)


func test_scale_respects_a_custom_tier_floor_distance() -> void:
	# The marker tier shrinks toward its own (further) fade edge, not the name tier's.
	var s := NameplateLod.scale_for_distance(
		50.0,
		NameplateLod.SCALE_FULL_DISTANCE,
		NameplateLod.MARKER_FADE_END,
		NameplateLod.SCALE_FLOOR
	)
	assert_true(
		s > NameplateLod.SCALE_FLOOR and s < 1.0, "50 m is inside the marker tier's shrink band"
	)


# T-589: occlusion dim — pure math path (occlusion passed in as a bool; the ray check itself lives
# in the layer and is not headless-testable).
func test_occluded_alpha_dims_to_the_mult() -> void:
	assert_almost_eq(
		NameplateLod.occluded_alpha(1.0, true), NameplateLod.OCCLUDED_ALPHA_MULT, 0.001
	)


func test_unoccluded_alpha_is_unchanged() -> void:
	assert_eq(NameplateLod.occluded_alpha(0.8, false), 0.8)


func test_occluded_marker_alpha_is_the_mult_of_unoccluded() -> void:
	var base := NameplateLod.alpha_for_distance(
		45.0, NameplateLod.MARKER_FADE_START, NameplateLod.MARKER_FADE_END
	)
	var visible := NameplateLod.occluded_alpha(base, false)
	var occluded := NameplateLod.occluded_alpha(base, true)
	assert_almost_eq(occluded, visible * NameplateLod.OCCLUDED_ALPHA_MULT, 0.001)


# T-656: near-camera clamp (point-blank nameplate blow-up) — full size at/beyond NEAR_CLAMP_M,
# shrinks proportionally below it (cancelling perspective growth), floors at zero, never > 1.
func test_near_clamp_scale_full_size_shrink_and_bounds() -> void:
	assert_eq(NameplateLod.near_clamp_scale(NameplateLod.NEAR_CLAMP_M), 1.0)
	assert_eq(NameplateLod.near_clamp_scale(10.0), 1.0, "far away — untouched")
	var half := NameplateLod.NEAR_CLAMP_M * 0.5
	assert_almost_eq(NameplateLod.near_clamp_scale(half), 0.5, 0.001, "half distance -> half scale")
	assert_eq(NameplateLod.near_clamp_scale(0.0), 0.0, "point-blank floors at zero, not negative")
	assert_true(NameplateLod.near_clamp_scale(100.0) <= 1.0, "never grows past full size")
