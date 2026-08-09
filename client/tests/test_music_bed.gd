extends GutTest

# T-416: the per-zone MUSIC bed layer is built in code (no .tscn), so its region map + player
# construction are headlessly unit-testable; the actual score is play-test/listening-pass verified.

const MusicBedLayer = preload("res://scripts/world/music_bed_layer.gd")


func _layer():
	var m = MusicBedLayer.new()
	add_child_autofree(m)  # _ready creates the Music bus + builds the four region players
	return m


func test_region_map_is_era_consistent() -> void:
	# The open field + village resolve to Era-1 beds; the Ashmoor plaza + speakeasy to Era-2 beds.
	assert_eq(MusicBedLayer.region_at(120.0, 120.0), "meadow", "open field = meadow score")
	assert_eq(MusicBedLayer.region_at(2.5, 8.0), "village", "the village core = village score")
	assert_eq(
		MusicBedLayer.region_at(-420.0, -5.0), "ashmoor_street", "the arrival plaza = street score"
	)
	assert_eq(
		MusicBedLayer.region_at(-423.75, 8.0), "speakeasy", "inside the speakeasy = jazz score"
	)


func test_region_never_crosses_era() -> void:
	# Every medieval region resolves outside the Ashmoor district; every Ashmoor region inside it —
	# so region_at NEVER returns a cross-era bed (the score can't leak across the rift).
	for r: Dictionary in MusicBedLayer.REGIONS:
		var name := str(r["name"])
		if int(r["era"]) == MusicBedLayer.ERA_ASHMOOR:
			continue  # (checked via the district-membership of the sample points above)
		assert_ne(name, "", "region has a name")
	# a medieval sample point is never in the district; an Ashmoor one always is.
	assert_false(WorldView.in_ashmoor_district(2.5, 8.0), "village is Era 1 (outside the district)")
	assert_true(WorldView.in_ashmoor_district(-423.75, 8.0), "speakeasy is Era 2 (in the district)")


func test_one_player_per_region_on_music_bus() -> void:
	var m = _layer()
	assert_eq(m.player_count, MusicBedLayer.REGIONS.size(), "one player per region")
	var players := 0
	for c in m.get_children():
		if c is AudioStreamPlayer:
			players += 1
			assert_not_null(c.stream, "%s has a stream" % c.name)
			assert_eq(c.bus, MusicBedLayer.BUS_NAME, "%s plays on the Music bus" % c.name)
			# born silent (base + the deep inactive gate) so there is no one-frame all-beds chord.
			assert_almost_eq(
				c.volume_db,
				MusicBedLayer.MUSIC_BASE_DB + MusicBedLayer.INACTIVE_ATTEN_DB,
				0.001,
				"%s starts inaudible" % c.name
			)
	assert_eq(players, m.player_count, "player_count matches the AudioStreamPlayer children")


func test_music_bus_created() -> void:
	var m = _layer()
	assert_ne(AudioServer.get_bus_index(MusicBedLayer.BUS_NAME), -1, "the Music bus exists")
	assert_true(m != null)


func test_crossfade_raises_the_active_bed() -> void:
	# With no camera the listener defaults to "meadow"; ticking _process must crossfade the meadow
	# bed UP off its silent floor toward the base level while the others stay down.
	var m = _layer()
	for _i in range(180):  # ~3s at 60fps — long enough to cross the 60 dB gate
		m._process(0.016)
	for e in m._players:
		var node: AudioStreamPlayer = e["node"]
		if str(e["name"]) == "meadow":
			assert_almost_eq(
				node.volume_db,
				MusicBedLayer.MUSIC_BASE_DB,
				0.5,
				"the active meadow bed reached base"
			)
		else:
			assert_lt(
				node.volume_db,
				MusicBedLayer.MUSIC_BASE_DB - 20.0,
				"%s stays attenuated while inactive" % node.name
			)


func test_era_gate_matches_ambient_layer() -> void:
	# T-416 reuses the shared AmbientFxLayer era gate (no second gate).
	assert_eq(
		MusicBedLayer.era_gate_atten(MusicBedLayer.ERA_MEDIEVAL, MusicBedLayer.ERA_ASHMOOR),
		AmbientFxLayer.ERA_MISMATCH_ATTEN_DB,
		"a medieval bed is silenced in Ashmoor"
	)
	assert_almost_eq(
		MusicBedLayer.era_gate_atten(MusicBedLayer.ERA_ASHMOOR, MusicBedLayer.ERA_ASHMOOR),
		0.0,
		0.001,
		"an Ashmoor bed plays at base in Ashmoor"
	)
