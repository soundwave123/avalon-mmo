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
	#
	# T-756: the old body looped over REGIONS asserting only that each name was non-empty, then
	# checked two hand-picked district-membership points. It never related a POSITION to the era
	# of the region region_at picks for it — so the invariant this function is named for went
	# untested, and region_at could have handed back "speakeasy" out in the meadow forever.
	var era_by_name := {}
	for r: Dictionary in MusicBedLayer.REGIONS:
		era_by_name[str(r["name"])] = int(r["era"])

	var violations: Array = []
	var seen_medieval := 0
	var seen_ashmoor := 0
	for xi in range(-600, 601, 25):
		for zi in range(-600, 601, 25):
			var x := float(xi)
			var z := float(zi)
			var region := MusicBedLayer.region_at(x, z)
			var in_district := WorldView.in_ashmoor_district(x, z)
			var expected: int = (
				MusicBedLayer.ERA_ASHMOOR if in_district else MusicBedLayer.ERA_MEDIEVAL
			)
			if in_district:
				seen_ashmoor += 1
			else:
				seen_medieval += 1
			if int(era_by_name.get(region, -1)) != expected:
				violations.append(
					"(%.0f, %.0f) is era %d but region_at chose '%s'" % [x, z, expected, region]
				)

	assert_eq(
		violations, [], "no point on the map gets a cross-era bed: %s" % [violations.slice(0, 5)]
	)
	# Both branches must really have been walked, or an always-false district test would make the
	# sweep above vacuously true — the same hole in a different disguise.
	assert_gt(seen_medieval, 0, "the sweep covered ground outside the Ashmoor district")
	assert_gt(seen_ashmoor, 0, "the sweep covered ground inside the Ashmoor district")


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
	var idx := AudioServer.get_bus_index(MusicBedLayer.BUS_NAME)
	assert_ne(idx, -1, "the Music bus exists")
	# T-756: the second assertion here was `assert_true(m != null)` — _layer() cannot return null,
	# so it was a tautology inflating the assert count. Assert what the bus is FOR instead: its
	# own send to Master is the whole reason it exists (it lets the settings slider trim the score
	# without touching ambience or SFX).
	assert_eq(str(AudioServer.get_bus_send(idx)), "Master", "the Music bus routes to Master")
	assert_eq(m.player_count, MusicBedLayer.REGIONS.size(), "and carries one bed per region")


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
