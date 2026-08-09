extends GutTest

# T-595: the client half of the per-zone content pipeline's integrity gate — the DRESSING oracle.
# tools/zonegen/zonegen.py scatters each zone's biome kit into client/assets/props.json under the
# tag 'zone_<id>' (terrain-oracle-seated, streamed FLORA-tier per T-594). This test re-runs the
# placement invariants over the emitted rows so a future zonegen run can't ship dressing that floats
# off the ground, strays into another region, blocks the world with solids, resurrects a
# realism-pivot-banned species, or breaks the T-594 streaming contract. Fails CLOSED.
#
# Scoped to Heartwold (the phase-1 proof); a new zone adds its tag to _ZONE_TAGS.

const _PS = preload("res://scripts/world/prop_streamer.gd")
const _TF = preload("res://scripts/world/terrain_field.gd")

const _ZONE_TAGS := ["zone_heartwold"]
# test_temperate_flora.gd's realism-pivot ban list — cartoon/new-world/anachronistic species.
const _BANNED_SPECIES := ["agave", "aloe", "succulent", "rooibos", "maize", "potato", "tomato"]
const _SEAT_TOL := 0.15  # world-audit.py's float/sink tolerance (m)
const _RIM_RADIUS := 560.0  # dressing stays inside the mountain/fog rim (owned by t587_boundary)
# Key exclusions the dressing must respect (mirror data/zones/heartwold.json exclusions).
const _LAKE := Vector2(18.0, 22.0)
const _CORE_R := 62.0
const _CITY := {"cx": 0.0, "cz": -240.0, "hx": 140.0, "hz": 120.0}


func _zone_props() -> Array:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/props.json"))
	var props: Array = raw["props"] if raw is Dictionary and raw.has("props") else []
	var out: Array = []
	for p in props:
		if p is Dictionary and str(p.get("tag", "")) in _ZONE_TAGS:
			out.append(p)
	return out


func test_zone_dressing_exists_as_a_real_scatter() -> void:
	var props := _zone_props()
	assert_gt(props.size(), 400, "the zone dressing pass placed a real, dense scatter (not a stub)")


func test_every_dressing_prop_is_resident_in_its_own_region_and_streams() -> void:
	# Region residency (T-594): every prop routes (nearest-origin) to the Wold region (index 0),
	# and classifies FLORA so prop_streamer streams it by distance rather than pinning it resident.
	var field = _TF.new()
	var origins: Array = field.region_origins()
	var wold_idx: int = _PS.region_of(Vector2(0.0, 0.0), origins)
	for p in _zone_props():
		var ground := Vector2(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		assert_eq(
			_PS.region_of(ground, origins),
			wold_idx,
			"dressing prop %s must reside in the Wold region (nearest-origin)" % ground
		)
		var base := str(p.get("scene", "")).get_file()
		assert_eq(
			_PS.classify(base, str(p.get("tag", ""))),
			_PS.TIER_FLORA,
			"dressing prop %s must be FLORA-tier (streamed, not resident chrome)" % base
		)
		assert_true(
			_PS.flora_streamable(base, {}), "dressing prop %s streams (not a critter)" % base
		)


func test_every_dressing_prop_is_terrain_seated() -> void:
	# Seating (gate7 reseat pattern): terrain_y matches the SAME TerrainField.height the rendered
	# ground uses, within the world-audit float/sink tolerance — no floating or sunk flora.
	var field = _TF.new()
	var checked := 0
	for p in _zone_props():
		var x := float(p.get("x", 0.0))
		var z := float(p.get("y", 0.0))
		var seat := float(p.get("terrain_y", 0.0))
		var grade: float = field.height(x, z)
		assert_almost_eq(
			seat,
			grade,
			_SEAT_TOL,
			(
				"dressing prop at (%.1f,%.1f) seated at %.3f but the ground is %.3f (floats/sinks)"
				% [x, z, seat, grade]
			)
		)
		checked += 1
	assert_gt(checked, 0, "dressing props were audited (data actually loaded)")


func test_dressing_uses_no_banned_species_and_stays_off_water_and_hubs() -> void:
	for p in _zone_props():
		var scene := str(p.get("scene", "")).to_lower()
		for banned in _BANNED_SPECIES:
			assert_false(
				scene.contains(banned), "dressing avoids banned species '%s' (%s)" % [banned, scene]
			)
		var x := float(p.get("x", 0.0))
		var z := float(p.get("y", 0.0))
		# Off the built core, the lake, the capital rect, and inside the rim.
		assert_gt(
			Vector2(x, z).length(),
			_CORE_R,
			"dressing at (%.1f,%.1f) stays out of the village core" % [x, z]
		)
		assert_gt(
			Vector2(x, z).distance_to(_LAKE),
			18.0,
			"dressing at (%.1f,%.1f) stays out of Crystal Lake" % [x, z]
		)
		var in_city: bool = (
			absf(x - _CITY["cx"]) <= _CITY["hx"] and absf(z - _CITY["cz"]) <= _CITY["hz"]
		)
		assert_false(
			in_city, "dressing at (%.1f,%.1f) stays out of the Highkeep footprint" % [x, z]
		)
		assert_lte(
			Vector2(x, z).length(),
			_RIM_RADIUS,
			"dressing at (%.1f,%.1f) stays inside the world rim" % [x, z]
		)
