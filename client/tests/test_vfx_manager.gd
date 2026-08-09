extends GutTest

# T-110: the VFX manager is built in code (one-shot particle pools), so its structure + the
# reposition/advance logic is headlessly unit-testable. The actual burst look is play-test-verified.

const VfxManager = preload("res://scripts/world/vfx_manager.gd")
const VfxStyles = preload("res://scripts/world/vfx_styles.gd")


func _v():
	var v = VfxManager.new()
	add_child_autofree(v)  # _ready builds the cast/impact/heal pools
	return v


func test_pools_built_as_one_shot_particles() -> void:
	var v = _v()
	assert_eq(v._cast.size(), 5, "cast pool")
	assert_eq(v._impact.size(), 6, "impact pool")
	assert_eq(v._heal.size(), 4, "heal pool")
	var gp := 0
	for c in v.get_children():
		if c is GPUParticles3D:
			gp += 1
			assert_true(c.one_shot, "%s is one-shot" % c.name)
			assert_not_null(c.process_material, "%s has a process material" % c.name)
			assert_not_null(c.draw_pass_1, "%s has a draw mesh" % c.name)
	# 5 cast + 6 impact + 4 heal primary emitters (a multi-emitter style's extras ride the primary,
	# so they are NOT direct children) + 4 T-350 gun-muzzle emitters.
	assert_eq(gp, 19, "15 house-style primary emitters + 4 T-350 gun-muzzle emitters")


# T-343 phase 3: the LIVE default (no AVALON_VFX_PRESET) wires the owner-chosen house styles per hit
# type from vfx_styles.json — impact grounded (embers + a dust child emitter), cast handglow (+ a
# hand-glow light), heal motes, projectile comet — while the frost bolt keeps its ability lance.
func test_house_styles_are_the_live_default() -> void:
	var v = _v()
	assert_null(v._lance, "no global gallery lance on the live default")
	assert_not_null(v._frost_lance, "frost bolt keeps its ability-routed Ice Lance")
	# impact 'grounded' is a 2-emitter style: the dust puff rides the ember primary as a child.
	var dust := 0
	for ch in v._impact[0].get_children():
		if ch is GPUParticles3D:
			dust += 1
	assert_eq(dust, 1, "grounded impact carries its dust emitter as a child of the primary")
	assert_not_null(v._cast_light, "handglow cast builds a hand-glow light")
	assert_true(v._cast_light is OmniLight3D, "the hand-glow is a real light")
	# projectile 'comet' flies faster than the classic orb (its data speed, not the baseline 20).
	assert_almost_eq(v._proj_speed, 30.0, 0.001, "comet projectile speed is data-driven")
	# spawning the hand-glow cast pulses the light and does not throw.
	v.spawn_cast(Vector3.ZERO)
	assert_gt(v._cast_light.light_energy, 0.0, "casting pulses the hand-glow light")


func test_spawn_impact_repositions_and_advances() -> void:
	var v = _v()
	v.spawn_impact(Vector3(5.0, 0.0, 5.0))
	assert_almost_eq(v._impact[0].global_position.y, 1.1, 0.05, "impact lifted above the target")
	assert_almost_eq(v._impact[0].global_position.x, 5.0, 0.05, "impact placed at the target x")
	assert_eq(v._ii, 1, "round-robin index advanced")


func test_spawn_all_kinds_are_safe() -> void:
	var v = _v()
	v.spawn_cast(Vector3.ZERO)
	v.spawn_heal(Vector3.ONE)
	v.spawn_impact(Vector3(2.0, 0.0, 2.0))
	assert_eq(v._ci, 1, "cast advanced")
	assert_eq(v._hi, 1, "heal advanced")


func test_projectile_pool_and_spawn() -> void:
	var v = _v()
	assert_eq(v._proj.size(), 4, "projectile pool built")
	assert_true(v._proj[0]["orb"] is MeshInstance3D, "projectile has an orb mesh")
	assert_true(v._proj[0]["trail"] is GPUParticles3D, "projectile has a trail")
	v.spawn_projectile(Vector3.ZERO, Vector3(10.0, 0.0, 10.0))
	assert_true(v._proj[0]["orb"].visible, "projectile orb shown on spawn")
	assert_eq(v._pi, 1, "projectile index advanced")


func test_gun_pools_built() -> void:
	# T-350: the "satisfying shot" pools are built preset-independently in _ready.
	var v = _v()
	assert_eq(v._gun_muzzle.size(), 4, "muzzle-flash pool built")
	assert_eq(v._gun_tracers.size(), 4, "tracer pool built")
	assert_not_null(v._gun_light, "muzzle OmniLight built")
	assert_true(v._gun_light is OmniLight3D, "the flash pulse is a real light")
	for t in v._gun_tracers:
		assert_false(t.visible, "tracers start hidden")


func test_spawn_gunshot_fires_muzzle_and_tracer() -> void:
	var v = _v()
	var shooter := Node3D.new()
	add_child_autofree(shooter)
	shooter.global_position = Vector3(0.0, 0.0, 0.0)
	v.spawn_gunshot(shooter, Vector3(10.0, 0.0, 0.0))
	assert_eq(v._gmi, 1, "muzzle pool index advanced")
	assert_eq(v._gti, 1, "tracer pool index advanced")
	assert_true(v._gun_tracers[0].visible, "the tracer streak shows on the shot")
	assert_gt(v._gun_tracers[0].scale.z, 1.0, "tracer stretched along the shot length")
	assert_gt(v._gun_light.light_energy, 0.0, "muzzle light pulsed on the shot")


func test_spawn_gunshot_null_shooter_is_safe() -> void:
	# A shot whose shooter node is unknown has no muzzle direction, so the tracer is skipped (a
	# degenerate zero-length streak would flicker) — but the muzzle flash + impact still fire safely.
	var v = _v()
	v.spawn_gunshot(null, Vector3(3.0, 0.0, 3.0))
	assert_eq(v._gmi, 1, "muzzle flash still fires with no shooter node")
	assert_false(v._gun_tracers[0].visible, "no tracer drawn for a directionless shot")
