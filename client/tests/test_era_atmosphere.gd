extends GutTest

# T-408: the per-region atmosphere presets + transition math (EraAtmosphere, the pure half of the
# Ashmoor smog layer). The load-bearing contract is ZERO REGRESSION: ERA0 is byte-for-byte the
# current world_view.gd environment constants, so at blend 0 the home world is untouched. These
# tests assert that, plus a monotone (no-pop) crossing and the byte-identical smog-0 grade LUT.

const ERA_ATMOS = preload("res://scripts/world/era_atmosphere.gd")


# The exact world_view.gd constants ERA0 must reproduce. If world_view's env build changes, THIS
# must change too — the assertion is the tripwire that the era layer never silently drifts era 0.
func test_era0_is_byte_for_byte_the_current_world_view_constants() -> void:
	var e0 := ERA_ATMOS.ERA0
	assert_eq(e0["fog_density_floor"], 0.0026, "fog_density base (world_view env.fog_density)")
	assert_eq(e0["fog_light_color"], Color(0.75, 0.80, 0.86), "env.fog_light_color")
	assert_eq(e0["fog_aerial_perspective"], 0.75, "env.fog_aerial_perspective")
	assert_eq(e0["ambient_energy_scale"], 1.0, "ambient scale is an identity")
	assert_eq(e0["sun_energy_scale"], 1.0, "sun scale is an identity")
	assert_eq(e0["sky_energy"], 2.6, "sky_mat.energy_multiplier")
	assert_eq(e0["saturation"], 1.03, "env.adjustment_saturation")
	assert_eq(e0["smog"], 0.0, "no smog in the home world")


func test_lerp_at_zero_returns_era0_exactly() -> void:
	var out := ERA_ATMOS.lerp_preset(ERA_ATMOS.ERA0, ERA_ATMOS.ERA1, 0.0)
	for k in ERA_ATMOS.ERA0:
		assert_eq(out[k], ERA_ATMOS.ERA0[k], "blend 0 is the identity for %s" % k)


func test_lerp_at_one_returns_era1_exactly() -> void:
	var out := ERA_ATMOS.lerp_preset(ERA_ATMOS.ERA0, ERA_ATMOS.ERA1, 1.0)
	for k in ERA_ATMOS.ERA1:
		assert_eq(out[k], ERA_ATMOS.ERA1[k], "blend 1 reaches era 1 for %s" % k)


# The crossing must be smooth AND directional: fog/smog rise, light/saturation fall, no overshoot.
func test_transition_is_monotone_across_the_blend() -> void:
	var prev := ERA_ATMOS.lerp_preset(ERA_ATMOS.ERA0, ERA_ATMOS.ERA1, 0.0)
	for i in range(1, 21):
		var t := float(i) / 20.0
		var cur := ERA_ATMOS.lerp_preset(ERA_ATMOS.ERA0, ERA_ATMOS.ERA1, t)
		# Ashmoor is denser/greyer/darker as t rises — every driver moves one way only.
		assert_true(cur["fog_density_floor"] >= prev["fog_density_floor"], "fog non-decreasing")
		assert_true(cur["smog"] >= prev["smog"], "smog non-decreasing")
		assert_true(cur["saturation"] <= prev["saturation"], "saturation non-increasing")
		assert_true(cur["sky_energy"] <= prev["sky_energy"], "sky energy non-increasing")
		assert_true(
			cur["ambient_energy_scale"] <= prev["ambient_energy_scale"], "ambient non-increasing"
		)
		prev = cur


# advance() steps toward the target without overshoot -> a monotone, pop-free tween.
func test_advance_converges_without_overshoot() -> void:
	var v := 0.0
	var last := -1.0
	for _i in range(100):
		v = ERA_ATMOS.advance(v, 1.0, 0.4, 0.1)
		assert_true(v >= last, "rising toward target")
		assert_true(v <= 1.0, "never overshoots the target")
		last = v
	assert_almost_eq(v, 1.0, 0.0001, "reaches the target")
	# and back down, symmetric
	v = ERA_ATMOS.advance(1.0, 0.0, 0.4, 0.1)
	assert_true(v < 1.0 and v >= 0.0, "falls back toward 0 without undershoot")


# The grade LUT at smog 0 must equal the ORIGINAL zone grade byte-for-byte. Recompute the original
# formula here (WITHOUT the T-408 smog terms) and compare every voxel — the regression tripwire that
# the added smog lerps are true no-ops at smog 0.
func test_smog_zero_lut_matches_the_original_zone_grade() -> void:
	var got: Array = ERA_ATMOS.make_zone_lut_images(0.0)
	var n := 17
	assert_eq(got.size(), n, "17-slice 3D LUT")
	var mismatches := 0
	for bi in range(n):
		var ref := Image.create(n, n, false, Image.FORMAT_RGB8)
		for gi in range(n):
			for ri in range(n):
				var c := Vector3(ri, gi, bi) / float(n - 1)
				var lum := c.dot(Vector3(0.2126, 0.7152, 0.0722))
				var shadow := 1.0 - smoothstep(0.18, 0.55, lum)
				var highlight := smoothstep(0.55, 0.95, lum)
				c = c.lerp(Vector3(0.20, 0.26, 0.45) * (0.4 + lum), shadow * 0.22)
				c += Vector3(0.05, 0.02, -0.03) * shadow
				c += Vector3(0.06, 0.045, 0.01) * highlight
				c = c.lerp(Vector3(0.5, 0.5, 0.5), -0.06)
				ref.set_pixel(
					ri, gi, Color(clampf(c.x, 0, 1), clampf(c.y, 0, 1), clampf(c.z, 0, 1))
				)
		if (got[bi] as Image).get_data() != ref.get_data():
			mismatches += 1
	assert_eq(mismatches, 0, "smog-0 grade is byte-identical to the pre-T-408 zone LUT")


func test_smog_one_lut_actually_changes_the_grade() -> void:
	var base: Array = ERA_ATMOS.make_zone_lut_images(0.0)
	var smog: Array = ERA_ATMOS.make_zone_lut_images(1.0)
	var b8 := (base[8] as Image).get_data()
	var s8 := (smog[8] as Image).get_data()
	assert_ne(s8, b8, "smog 1 desaturates the grade")
