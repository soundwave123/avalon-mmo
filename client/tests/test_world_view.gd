extends GutTest

# T-053: the 3D world is built in code, so its STRUCTURE is unit-testable headlessly
# (add_child_autofree triggers _ready → builds the nodes; no rendering needed). The visual look
# is play-test-verified.

const WorldView = preload("res://scripts/world/world_view.gd")
const Meadow = preload("res://scripts/world/meadow_clutter.gd")
const RainRig = preload("res://scripts/world/rain_rig.gd")


func _world():
	var wv = WorldView.new()
	add_child_autofree(wv)  # _ready builds ground + lighting + camera
	return wv


func test_ground_has_visual_mesh_and_collision_floor() -> void:
	var wv = _world()
	assert_true(wv.ground is StaticBody3D, "ground is a StaticBody3D")
	var has_mesh := false
	var has_collision := false
	for c in wv.ground.get_children():
		if c is MeshInstance3D and c.mesh != null:
			has_mesh = true  # T-132: terrain is a displaced ArrayMesh now (was a flat PlaneMesh)
		if c is CollisionShape3D and c.shape != null:
			has_collision = true
	assert_true(has_mesh, "ground has a terrain mesh visual")
	assert_true(has_collision, "ground has a collision floor (nothing falls through)")


func test_lighting_and_sky_environment() -> void:
	var wv = _world()
	assert_true(wv.sun is DirectionalLight3D, "directional sun light")
	assert_not_null(wv.world_environment, "WorldEnvironment exists")
	assert_not_null(wv.world_environment.environment, "environment resource set")
	assert_eq(
		wv.world_environment.environment.background_mode, Environment.BG_SKY, "sky background"
	)


func test_third_person_spring_arm_camera_rig() -> void:
	var wv = _world()
	assert_true(wv.camera_arm is SpringArm3D, "SpringArm3D rig (keeps the camera out of walls)")
	assert_true(wv.camera_arm.spring_length > 0.0, "non-zero spring length (camera distance)")
	assert_true(wv.camera is Camera3D, "Camera3D")
	assert_eq(wv.camera.get_parent(), wv.camera_arm, "camera is a child of the spring arm")
	assert_true(wv.camera.current, "camera is the active one")
	assert_eq(wv.get_camera(), wv.camera, "get_camera() returns it")


func test_hk_street_network_queries() -> void:
	# T-202: the street SDF answers the same question as the shader paint — plaza and
	# high street are trodden ground, the village green is not, the circuit rect holds.
	assert_lt(WorldView.hk_street_dist(0.0, -215.0), 0.0, "market plaza is street ground")
	assert_lt(WorldView.hk_street_dist(0.0, -150.0), 0.0, "high street is street ground")
	assert_lt(WorldView.hk_street_dist(78.0, -262.0), 0.0, "mage spur is street ground")
	assert_gt(WorldView.hk_street_dist(0.0, 0.0), 50.0, "village green fronts no city street")
	assert_true(WorldView.hk_in_city(0.0, -240.0), "city center inside the circuit")
	assert_false(WorldView.hk_in_city(0.0, 0.0), "village outside the circuit")


func test_clutter_stays_out_of_the_city() -> void:
	# T-202: no meadow tufts inside the walls — sample every scattered instance.
	var wv = _world()
	var violations := 0
	var sampled := 0
	for inst in wv.get_children():
		if inst is MultiMeshInstance3D and inst.name == "Clutter":
			var mm: MultiMesh = inst.multimesh
			for i in range(mm.instance_count):
				var p := (mm.get_instance_transform(i) as Transform3D).origin
				sampled += 1
				if WorldView.hk_in_city(p.x, p.z):
					violations += 1
	assert_gt(sampled, 1000, "clutter instances found to sample")
	assert_eq(violations, 0, "no clutter inside the city circuit")


# T-758 (items 3+4): the ~13.7k boot-scatter clutter instances shipped with NO visibility_range and
# no custom_aabb — the whole meadow drew from every zone and the engine recomputed each MultiMesh's
# bounds at build. Every scatter pool (8 grass/rock/flower MultiMeshes) must now carry BOTH a
# positive LodPolicy cull distance and a non-degenerate custom_aabb. (add_child gives the shared
# "Clutter" name to only the first pool, so identify pools by the LOD treatment itself.)
func test_boot_clutter_has_lod_range_and_custom_aabb() -> void:
	var wv = _world()
	var pools := 0
	for inst in wv.get_children():
		if not (inst is MultiMeshInstance3D):
			continue
		var aabb: AABB = (inst.multimesh as MultiMesh).custom_aabb
		if inst.visibility_range_end > 0.0 and aabb.size != Vector3.ZERO:
			pools += 1
	# 8 scatter pools carry both; AshmoorLitter (its own build) stays uncapped and is not counted.
	assert_gte(pools, 8, "every grass/rock/flower scatter pool got a cull range + custom_aabb")


# T-490: the ambient meadow tuft must read as UPRIGHT temperate grass, not a splayed agave/aloe
# rosette. The mesh is clearly taller than wide (a fleshy outward-arcing dome is roughly as wide as
# it is tall), and the blades are narrow.
func test_meadow_tuft_is_upright_grass_not_a_splayed_rosette() -> void:
	var mesh: Mesh = Meadow.build_tuft_mesh(
		WorldView.GRASS_SHADER,
		null,
		Color(0.3, 0.42, 0.2),
		Color(0.1, 0.18, 0.08),
		Vector4(0.30, 7, 0.014, 0.05)
	)
	var aabb := mesh.get_aabb()
	var horiz: float = maxf(aabb.size.x, aabb.size.z)
	assert_gt(
		aabb.size.y, horiz * 1.6, "tuft is upright grass (taller than wide), not a splayed dome"
	)
	assert_lt(horiz, 0.35, "blades are narrow — no wide fleshy outward-arcing succulent rosette")


# T-490: the ground-cover density field is patchy (real bare gaps + dense drifts), not a uniform
# carpet, and it runs thicker on the paddock fence-line than on the cropped common beside it. Off
# the road/path/water features (passed as sentinels here), only the noise base + fence drift apply.
func test_meadow_density_field_is_patchy_not_a_uniform_carpet() -> void:
	var noise := Meadow.make_noise()
	var lo := 0
	var hi := 0
	for gx in range(-30, 31, 3):
		for gz in range(30, 61, 3):
			var d: float = Meadow.density(
				float(gx),
				float(gz),
				noise,
				WorldView.LAKE_CENTER,
				WorldView.LAKE_RADIUS,
				999.0,
				999.0,
				999.0,
				[],
				WorldView.PLOT_RADIUS,
				WorldView.PADDOCK_RECT
			)
			if d < 0.12:
				lo += 1
			elif d > 0.55:
				hi += 1
	assert_gt(lo, 0, "meadow has genuine bare patches (near-zero density) — not a uniform lawn")
	assert_gt(hi, 0, "meadow has dense drifts (high density) — measurable non-uniformity")
	# Fence-line vs cropped common: average over a band so the low-freq noise washes out.
	var fence_sum := 0.0
	var common_sum := 0.0
	for t in range(11):
		var fx := 21.0 + float(t)  # along the paddock's +z fence rail (x 21..31, z just outside)
		fence_sum += Meadow.density(
			fx,
			8.4,
			noise,
			WorldView.LAKE_CENTER,
			WorldView.LAKE_RADIUS,
			999.0,
			999.0,
			999.0,
			[],
			WorldView.PLOT_RADIUS,
			WorldView.PADDOCK_RECT
		)
		common_sum += Meadow.density(
			30.0 + float(t),
			40.0,
			noise,
			WorldView.LAKE_CENTER,
			WorldView.LAKE_RADIUS,
			999.0,
			999.0,
			999.0,
			[],
			WorldView.PLOT_RADIUS,
			WorldView.PADDOCK_RECT
		)
	assert_gt(
		fence_sum / 11.0,
		common_sum / 11.0,
		"grass drifts thicker on the fence-line than on the open cropped common"
	)


# T-187: indoor rain gating — set_rain_suppressed() must stop the drops WITHOUT resetting the
# outdoor overcast look (fog/ambient), and must resume exactly what set_rain() last asked for
# once the player steps back outside (not force rain on if the weather was actually clear).
func test_rain_suppressed_stops_particles_without_touching_the_overcast_look() -> void:
	var wv = _world()
	wv.set_rain(true)
	var fog_while_raining: float = wv.world_environment.environment.fog_density
	assert_true(wv.rain.emitting, "rain emits once the weather system asks for it")
	wv.set_rain_suppressed(true)
	assert_false(wv.rain.emitting, "suppressed indoors: no drops")
	assert_almost_eq(
		wv.world_environment.environment.fog_density,
		fog_while_raining,
		0.0001,
		"the outdoor overcast look is untouched by indoor suppression"
	)


func test_rain_suppressed_resumes_whatever_set_rain_last_asked_for() -> void:
	var wv = _world()
	wv.set_rain(true)
	wv.set_rain_suppressed(true)  # walk indoors
	wv.set_rain_suppressed(false)  # walk back out
	assert_true(wv.rain.emitting, "weather was on, so it resumes on exit")


func test_rain_suppressed_does_not_force_rain_on_when_weather_is_clear() -> void:
	var wv = _world()
	wv.set_rain(false)  # clear weather, never asked for rain
	wv.set_rain_suppressed(true)
	wv.set_rain_suppressed(false)
	assert_false(wv.rain.emitting, "suppression toggling never invents rain that wasn't wanted")


# T-614: the emitter must NOT hang off WorldView's preview camera_arm — local_player builds its
# own rig and takes over (camera.current), so a preview-parented emitter stays parked at the
# origin forever and the "camera-following" rain never falls anywhere a player stands. It is
# world-parented and re-parked over the ACTIVE viewport camera every _process tick.
func test_rain_emitter_is_world_parented_and_follows_the_active_camera() -> void:
	var wv = _world()
	assert_eq(wv.rain.get_parent(), wv, "rain is world-parented, not hung off the preview arm")
	wv.camera_arm.position = Vector3(120.0, 2.0, -80.0)  # move the live (preview) camera far away
	wv._process(0.016)
	var expected: Vector3 = (
		wv.get_camera().global_position + Vector3(0.0, RainRig.CAMERA_HEIGHT, 0.0)
	)
	assert_lt(
		wv.rain.global_position.distance_to(expected),
		0.01,
		"after a tick the emitter rides CAMERA_HEIGHT above the live camera, wherever it moved"
	)


# T-614: headless sanity on the parts of the particle system a screenshot would exercise — a
# dead/invisible draw pass or an AABB that can't contain the fall would ship invisible rain again.
func test_rain_particle_material_and_visibility_aabb_are_sane() -> void:
	var wv = _world()
	var r: GPUParticles3D = wv.rain
	assert_gt(r.amount, 0, "emitter has particles")
	var proc := r.process_material as ParticleProcessMaterial
	assert_not_null(proc, "process material drives the drops")
	var streak := r.draw_pass_1
	assert_not_null(streak, "draw pass mesh exists")
	var mat := streak.material as StandardMaterial3D
	assert_not_null(mat, "draw pass mesh carries a material")
	assert_gt(mat.albedo_color.a, 0.05, "streaks are not zero-alpha (invisible)")
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA, "alpha transparency is enabled")
	# The node-local visibility AABB must enclose the emission sheet and the full fall distance,
	# or the whole system culls/clips while "emitting" just fine.
	var fall := (
		proc.initial_velocity_max * r.lifetime
		+ 0.5 * absf(proc.gravity.y) * r.lifetime * r.lifetime
	)
	var aabb := r.visibility_aabb
	assert_lt(aabb.position.y, -fall, "AABB reaches below the deepest a drop can fall")
	assert_true(
		(
			aabb.position.x <= -proc.emission_box_extents.x
			and aabb.position.x + aabb.size.x >= proc.emission_box_extents.x
		),
		"emission sheet fits inside the visibility AABB on x"
	)
	assert_true(
		(
			aabb.position.z <= -proc.emission_box_extents.z
			and aabb.position.z + aabb.size.z >= proc.emission_box_extents.z
		),
		"emission sheet fits inside the visibility AABB on z"
	)


# ---- T-697 fix 4: night-lights cache — refreshed on tree change, quantized-change gating ----


func test_night_lights_cache_lights_a_streamed_in_lamp_at_night() -> void:
	var wv = _world()
	wv._day_frozen = true
	wv._day_t = 0.75  # midnight — night factor 1.0
	var lamp := OmniLight3D.new()
	lamp.set_meta("base_energy", 3.0)
	lamp.light_energy = 0.0
	lamp.add_to_group("night_lights")  # group BEFORE entering the tree (world_props idiom)
	add_child_autofree(lamp)
	wv._process(0.016)
	assert_almost_eq(lamp.light_energy, 3.0, 0.01, "a lamp in the cache lights at full night")
	assert_true(lamp.visible, "night > 0.02 keeps the lamp visible")
	assert_true(wv._night_lights.has(lamp), "the cached list picked the lamp up")


func test_night_lights_cache_refreshes_when_a_lamp_streams_out_and_another_in() -> void:
	var wv = _world()
	wv._day_frozen = true
	wv._day_t = 0.75
	var first := OmniLight3D.new()
	first.set_meta("base_energy", 2.0)
	first.add_to_group("night_lights")
	add_child(first)
	wv._process(0.016)
	assert_true(wv._night_lights.has(first), "first lamp cached")
	remove_child(first)  # streams out (region swap) — node_removed marks the cache dirty
	first.free()
	var second := OmniLight3D.new()
	second.set_meta("base_energy", 4.0)
	second.light_energy = 0.0
	second.add_to_group("night_lights")
	add_child_autofree(second)
	wv._process(0.016)
	assert_true(wv._night_lights.has(second), "the cache rebuilt with the streamed-in lamp")
	assert_almost_eq(second.light_energy, 4.0, 0.01, "the fresh lamp got the current night level")
	assert_eq(wv._night_lights.size(), 1, "the streamed-out lamp left the cache")
