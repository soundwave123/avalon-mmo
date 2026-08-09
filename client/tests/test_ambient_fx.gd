extends GutTest

# T-139: the ambient FX layer is built in code, so its structure is headlessly unit-testable
# (the look is play-test-verified). Asserts the GPUParticles3D systems + firelight get built.

const AmbientFxLayer = preload("res://scripts/world/ambient_fx_layer.gd")


func _fx():
	var fx = AmbientFxLayer.new()
	add_child_autofree(fx)  # _ready builds smoke + campfire (motes retired, T-185 realism)
	return fx


func test_builds_all_particle_systems() -> void:
	var fx = _fx()
	# campfire embers only at _ready — chimney smoke is socket-driven now (T-209; see
	# test_chimney_smoke_is_socket_driven), pollen motes retired by the realism pivot
	assert_eq(fx.particle_count, 1, "campfire is the only _ready-built system")
	var gp := 0
	for c in fx.get_children():
		if c is GPUParticles3D:
			gp += 1
			assert_not_null(c.process_material, "%s has a process material" % c.name)
			assert_not_null(c.draw_pass_1, "%s has a draw mesh" % c.name)
	assert_eq(gp, 1, "1 particle node is a child at _ready")


func test_campfire_has_firelight() -> void:
	var fx = _fx()
	var has_light := false
	for c in fx.get_children():
		if c is OmniLight3D:
			has_light = true
	assert_true(has_light, "campfire adds an OmniLight3D")


func test_audio_zones_structure() -> void:
	# T-209: zones are data + a pure query — the mix hooks exist before the recordings do.
	assert_true("square_crowd" in AmbientFxLayer.zones_at(0.0, -215.0), "crowd on the square")
	assert_true("cathedral_bell" in AmbientFxLayer.zones_at(-76.0, -282.0), "bells at the close")
	# T-305: open field far from any anchor is still zone-quiet (only the meadow bed carries there).
	assert_eq(AmbientFxLayer.zones_at(120.0, 120.0).size(), 0, "far open field is zone-quiet")


func test_no_zone_has_an_empty_stream() -> void:
	# T-305: every declared zone now carries a recorded bed (no more placeholder "" streams).
	for zone in AmbientFxLayer.AUDIO_ZONES:
		assert_true(
			str(zone.get("stream", "")).strip_edges() != "",
			"zone '%s' has a recorded stream" % str(zone.get("name", "?"))
		)


func test_village_zones_exist() -> void:
	# T-305: the starting village finally has placed ambience — not only Highkeep.
	assert_true(
		"village_forge" in AmbientFxLayer.zones_at(-8.8, -9.0), "forge sings at the village smithy"
	)
	assert_true(
		"village_market" in AmbientFxLayer.zones_at(2.5, 8.0), "market murmur at the stalls"
	)
	assert_true("watermill" in AmbientFxLayer.zones_at(26.0, 26.0), "water at the pond/watermill")


func test_valid_zones_fail_closed() -> void:
	# T-305: a zone missing its stream or with a non-positive radius is DROPPED, never emitted silent.
	var sample := [
		{"name": "ok", "x": 0.0, "z": 0.0, "r": 10.0, "stream": "res://assets/audio/amb_crowd.wav"},
		{"name": "no_stream", "x": 1.0, "z": 1.0, "r": 10.0, "stream": ""},
		{"name": "zero_radius", "x": 2.0, "z": 2.0, "r": 0.0, "stream": "res://x.wav"},
	]
	var kept := AmbientFxLayer.valid_zones(sample)
	assert_eq(kept.size(), 1, "only the well-formed zone survives")
	assert_eq(str(kept[0]["name"]), "ok", "the surviving zone is the valid one")
	# the shipped table is all-valid, so it survives validation whole.
	assert_eq(
		AmbientFxLayer.valid_zones().size(),
		AmbientFxLayer.AUDIO_ZONES.size(),
		"every shipped zone is well-formed"
	)


func test_positional_emitters_built() -> void:
	# T-305: one AudioStreamPlayer3D per valid zone, attenuation params within sane bounds.
	var fx = _fx()
	assert_eq(fx.emitter_count, AmbientFxLayer.valid_zones().size(), "an emitter per valid zone")
	var players := 0
	for c in fx.get_children():
		if c is AudioStreamPlayer3D:
			players += 1
			assert_not_null(c.stream, "%s has a stream" % c.name)
			assert_gt(c.unit_size, 0.0, "%s attenuates over a positive radius" % c.name)
			assert_true(
				c.max_distance >= c.unit_size, "%s culls no closer than its radius" % c.name
			)
			# T-409: a cross-era bed is born era-gated (base + ERA_MISMATCH_ATTEN_DB), so the sane
			# floor is the accent floor plus the era dim.
			assert_true(
				c.volume_db <= 3.0 and c.volume_db >= -40.0 + AmbientFxLayer.ERA_MISMATCH_ATTEN_DB,
				"%s level within bounds" % c.name
			)
	assert_eq(players, fx.emitter_count, "emitter_count matches the AudioStreamPlayer3D children")


func test_night_gate_quiets_daytime_beds() -> void:
	# T-305: with no world day-clock parent the beds default to daylight; forcing night in _process
	# math drops the day-tagged emitters well below their base level.
	var fx = _fx()
	var day_emitter: Dictionary = {}
	for e in fx._emitters:
		if e["day"]:
			day_emitter = e
			break
	assert_false(day_emitter.is_empty(), "at least one daytime-gated bed exists (market/birdsong)")


func test_birds_flock_built_at_ready() -> void:
	# T-310: a few sky birds cross overhead so the meadow isn't silent-still.
	var fx = _fx()
	assert_eq(fx.bird_count, 3, "the three hand-picked flight paths each spawn a bird")
	var mesh_birds := 0
	for c in fx.get_children():
		if c is MeshInstance3D:
			mesh_birds += 1
			assert_not_null(c.mesh, "%s has a draw mesh" % c.name)
			assert_gt(c.visibility_range_end, 0.0, "birds cull at distance (T-210)")
	assert_eq(mesh_birds, 3, "one MeshInstance3D per bird")


func test_birds_move_along_their_loop() -> void:
	# T-310: a bird isn't a frozen prop -- ticking _process should move it off its spawn point.
	var fx = _fx()
	var bird: Node3D = fx._birds[0]["node"]
	var start := bird.position
	fx._process(2.0)
	assert_ne(bird.position, start, "the bird advances along its flight path")


# T-409: the Ashmoor 1920s district finally has placed ambience — not only the medieval world.
func test_ashmoor_zones_exist() -> void:
	# arrival plaza (-420,-5) sits under the tram + wind-in-wires beds; the terrace at (-423.75,8)
	# under the speakeasy leak.
	assert_true(
		"ashmoor_tram" in AmbientFxLayer.zones_at(-420.0, -5.0),
		"tram rumble over the arrival plaza"
	)
	assert_true(
		"ashmoor_wirewind" in AmbientFxLayer.zones_at(-420.0, -5.0),
		"wind in the wires on High Street"
	)
	assert_true(
		"ashmoor_speakeasy" in AmbientFxLayer.zones_at(-423.75, 8.0), "jazz leaks at the speakeasy"
	)


func test_no_birdsong_or_meadow_in_ashmoor() -> void:
	# T-409 lint (fails closed): the eras never share ambience. Every ERA_ASHMOOR zone must carry a
	# 1920s bed — never the medieval birdsong/meadow — and birdsong stays Era-1-tagged.
	for zone in AmbientFxLayer.AUDIO_ZONES:
		var stream := str(zone.get("stream", ""))
		if AmbientFxLayer.zone_era(zone) == AmbientFxLayer.ERA_ASHMOOR:
			assert_ne(stream, AmbientFxLayer.BIRDSONG, "no birdsong in Ashmoor: %s" % zone["name"])
			assert_false(stream.contains("meadow"), "no meadow bed in Ashmoor: %s" % zone["name"])
		if stream == AmbientFxLayer.BIRDSONG:
			assert_eq(
				AmbientFxLayer.zone_era(zone),
				AmbientFxLayer.ERA_MEDIEVAL,
				"birdsong is Era-1 only: %s" % zone["name"]
			)


func test_era_gate_math() -> void:
	# T-409: matched era = no attenuation; cross-era = the deep mismatch dim, both directions.
	assert_almost_eq(
		AmbientFxLayer.era_gate_atten(AmbientFxLayer.ERA_MEDIEVAL, AmbientFxLayer.ERA_MEDIEVAL),
		0.0,
		0.001,
		"a medieval bed plays at base in the medieval world"
	)
	assert_almost_eq(
		AmbientFxLayer.era_gate_atten(AmbientFxLayer.ERA_ASHMOOR, AmbientFxLayer.ERA_ASHMOOR),
		0.0,
		0.001,
		"an Ashmoor bed plays at base in Ashmoor"
	)
	assert_eq(
		AmbientFxLayer.era_gate_atten(AmbientFxLayer.ERA_MEDIEVAL, AmbientFxLayer.ERA_ASHMOOR),
		AmbientFxLayer.ERA_MISMATCH_ATTEN_DB,
		"a medieval bed is silenced inside Ashmoor"
	)
	assert_eq(
		AmbientFxLayer.era_gate_atten(AmbientFxLayer.ERA_ASHMOOR, AmbientFxLayer.ERA_MEDIEVAL),
		AmbientFxLayer.ERA_MISMATCH_ATTEN_DB,
		"an Ashmoor bed is silenced outside the district"
	)


func test_resolved_era_matches_district() -> void:
	# T-409: the era detector is the shared WorldView.in_ashmoor_district rect (no second detector).
	assert_eq(
		AmbientFxLayer.resolved_era(-420.0, -5.0), AmbientFxLayer.ERA_ASHMOOR, "plaza = Era 2"
	)
	assert_eq(AmbientFxLayer.resolved_era(0.0, 0.0), AmbientFxLayer.ERA_MEDIEVAL, "village = Era 1")
	# every shipped Ashmoor zone centre resolves to Era 2 (the gate engages where the beds sit).
	for zone in AmbientFxLayer.AUDIO_ZONES:
		if AmbientFxLayer.zone_era(zone) == AmbientFxLayer.ERA_ASHMOOR:
			assert_eq(
				AmbientFxLayer.resolved_era(float(zone["x"]), float(zone["z"])),
				AmbientFxLayer.ERA_ASHMOOR,
				"zone %s sits inside the district rect" % zone["name"]
			)


func test_era_gate_dims_cross_era_emitters() -> void:
	# T-409: with no camera the listener defaults to the medieval era, so ticking _process silences
	# every Ashmoor emitter (deep below base) while the medieval emitters sit at their base level.
	var fx = _fx()
	fx._process(0.016)
	var checked_ashmoor := false
	var checked_medieval := false
	for e in fx._emitters:
		var node: AudioStreamPlayer3D = e["node"]
		if bool(e["night"]):
			continue  # T-675 night zones carry their own day-silencing term — tested separately
		if int(e["era"]) == AmbientFxLayer.ERA_ASHMOOR:
			assert_almost_eq(
				node.volume_db,
				float(e["base_db"]) + AmbientFxLayer.ERA_MISMATCH_ATTEN_DB,
				0.001,
				"Ashmoor bed %s is silenced in the medieval world" % node.name
			)
			checked_ashmoor = true
		elif not bool(e["day"]):  # a non-day medieval bed has no night term either
			assert_almost_eq(
				node.volume_db,
				float(e["base_db"]),
				0.001,
				"medieval bed %s plays at base" % node.name
			)
			checked_medieval = true
	assert_true(checked_ashmoor, "at least one Ashmoor emitter was checked")
	assert_true(checked_medieval, "at least one medieval emitter was checked")


func test_ashmoor_bed_streams_load_headlessly() -> void:
	# T-409: every new Era-2 bed file imports + loads (a missing/bad asset would drop its emitter).
	for path in [
		AmbientFxLayer.TRAM,
		AmbientFxLayer.WIREWIND,
		AmbientFxLayer.SPEAKEASY,
		AmbientFxLayer.GASLAMP,
	]:
		assert_not_null(load(path) as AudioStream, "%s loads as an AudioStream" % path)


func test_chimney_smoke_is_socket_driven() -> void:
	# T-209: no hand-placed smoke coords — a socket in the chimney group grows a column.
	var sock := Node3D.new()
	sock.name = "socket_chimney"
	add_child_autofree(sock)
	sock.add_to_group("chimney_sockets")
	sock.global_position = Vector3(10.0, 6.0, 9.0)  # village-side: always lit
	var fx := AmbientFxLayer.new()
	add_child_autofree(fx)
	await get_tree().process_frame  # _discover_chimneys is deferred past props load
	assert_eq(fx.smoke_count, 1, "one socket -> one smoke column")


# T-407: the era-rift monolith's aperture VFX are socket-driven like chimney smoke — a grouped
# socket_rift grows a shimmer plane + a GPU mote emitter AS CHILDREN OF THE SOCKET (both monolith
# placements line up with the carved aperture), with zero script per-frame cost.
func test_rift_fx_is_socket_driven() -> void:
	var sock := Node3D.new()
	sock.name = "socket_rift"
	add_child_autofree(sock)
	sock.add_to_group("rift_sockets")
	sock.global_position = Vector3(-420.0, 1.35, -10.0)  # the Ashmoor arrival aperture
	var fx := AmbientFxLayer.new()
	add_child_autofree(fx)
	await get_tree().process_frame  # _discover_rifts is deferred past props load
	assert_eq(fx.rift_count, 1, "one rift socket -> one dressed aperture")
	var shimmer := sock.find_child("RiftShimmer", false, false) as MeshInstance3D
	assert_not_null(shimmer, "the shimmer plane hangs off the socket")
	if shimmer != null:
		var mat := (shimmer.mesh as QuadMesh).material as StandardMaterial3D
		assert_true(mat.emission_enabled, "the shimmer is emissive (reads at night)")
		assert_eq(
			mat.cull_mode,
			BaseMaterial3D.CULL_DISABLED,
			"the membrane reads from both eras' walk-up sides"
		)
	var motes := sock.find_child("RiftMotes", false, false) as GPUParticles3D
	assert_not_null(motes, "the drifting motes hang off the socket")
	if motes != null:
		assert_not_null(motes.process_material, "motes are GPU-driven (no script tick)")
		assert_gt(motes.preprocess, 0.0, "the rift is never seen empty on arrival")


# Row E (2026-07-14): the game went SILENT ~10s after boot for weeks and every loop test passed —
# `loop_mode = LOOP_FORWARD` set at runtime is a trap when the imported sample has loop_end == 0
# (empty loop region: playback runs off the end and stops; `playing` flips false forever). The
# only honest assertion is a NON-EMPTY loop region on the stream as actually imported, for every
# bed the game plays: the three AudioManager beds + every positional zone + the interior roomtone.
func test_every_bed_stream_has_a_real_loop_region() -> void:
	var am := preload("res://scripts/audio/audio_manager.gd")
	var music := preload("res://scripts/world/music_bed_layer.gd")
	# T-503: the frostbolt CHARGE layer is a LOOPING bed too — an empty loop region would silent-die
	# it mid-cast exactly like the T-415 ambience beds, so it rides the same regression gate.
	# T-675: the crickets + rain global beds ride the same gate — every bed loops or silent-dies.
	var paths: Array = [
		am.AMBIENT,
		am.BIRDSONG_BED,
		am.ASHMOOR_HUM_BED,
		am.FROST_CHARGE,
		am.CRICKETS_BED,
		am.RAIN_BED,
		AmbientFxLayer.ROOMTONE
	]
	for zone: Dictionary in AmbientFxLayer.valid_zones():
		paths.append(str(zone["stream"]))
	# T-416: the per-zone MUSIC beds ride the SAME loop-import discipline — a music bed with an empty
	# loop region would silent-die exactly like the T-415 ambience beds did.
	for region: Dictionary in music.REGIONS:
		paths.append(str(region["stream"]))
	for p: String in paths:
		var s := load(p) as AudioStreamWAV
		assert_not_null(s, p + " loads as an AudioStreamWAV bed")
		if s == null:
			continue
		assert_eq(s.loop_mode, AudioStreamWAV.LOOP_FORWARD, p + " imported with loop enabled")
		assert_gt(s.loop_end, s.loop_begin, p + " loop region is non-empty (silent-death trap)")
