extends GutTest

# T-327: drift alarm for the shared deterministic terrain-height field. The formula (extracted by
# T-309) is sampled by the client render, the world-audit oracle, AND the world server (a
# byte-identical copy under server/world, enforced by scripts/check_shared_files_sync.sh) — from
# (x, z) on every side — never on the wire — so a seed/coefficient change here would silently desync
# client and server ground. These baked fixed-point expectations (FastNoiseLite is deterministic per
# seed) fail loudly instead. The server test bakes the SAME fixtures.
#
# T-445 refreshed the fixtures for the walkable-relief pass: rolling meadows across the walked band,
# the King's Road swale, the carved riverbed, and the new flat pads (ward/bridge, crypt, arena,
# Ashmoor). The FLAT guarantees now live on the PADS (built clusters), not the whole walked floor.

const TERRAIN_FIELD := preload("res://scripts/world/terrain_field.gd")

# [x, z, expected_height] — flat pads (exact 0.0), rolling relief, swale, riverbed, ridge, ring.
const FIXTURES := [
	[0.0, 0.0, 0.0],  # village core centre — protected flat pad
	[10.0, 5.0, 0.24],  # T-559 training-yard dry pad — lifted clear of the y=0.06 water plane
	[50.0, -100.0, 0.272858],  # off-road meadow (gentle relief)
	[150.0, 150.0, 0.117201],  # open meadow swell
	[-200.0, 120.0, 0.217118],  # T-445: mid-band relief (was inside the retired T-309 near-fade)
	[0.0, -380.0, 4.928226],  # T-287 backdrop ridge behind Highkeep (never walked)
	[18.0, 22.0, -0.55],  # Crystal Lake bowl centre
	[300.0, -380.0, 5.007974],  # ridge + swell corner
	[560.0, 0.0, 33.340040],  # T-309 mountain ring — outside the ±500 clamp box
	[-620.0, -620.0, 89.258334],  # mountain ring corner
	[0.0, -80.0, -1.219954],  # T-445 King's Road swale — the road dips through a hollow
	[19.0, -126.0, -0.5],  # T-445 carved riverbed (below the y=0.06 water plane)
	[150.0, 0.0, 2.297025],  # T-445 rolling rise east of the vale
	[0.0, 150.0, -1.713331],  # T-445 rolling hollow north of the village
]


func test_baked_heights_match_to_1e4() -> void:
	var field = TERRAIN_FIELD.new()
	for f in FIXTURES:
		var got: float = field.height(f[0], f[1])
		assert_almost_eq(got, float(f[2]), 0.0001, "height(%s, %s) drift" % [f[0], f[1]])


func test_protected_flat_pads_stay_level() -> void:
	# Rigid one-piece GLBs (city walls/greybox/keep, the bridge, the crypt/arena/Ashmoor set
	# pieces) are seated at a single terrain_y, so their pads must read EXACTLY 0.0 (T-445 keeps
	# the pads level while the meadow between them rolls).
	var field = TERRAIN_FIELD.new()
	var flat_points := [
		Vector2(0.0, 0.0),  # core
		Vector2(20.0, -10.0),  # core interior
		Vector2(44.0, 20.0),  # farmstead (still inside the core pad)
		Vector2(0.0, -100.0),  # ward pad: bridge approach on the King's Road
		Vector2(5.2, -109.0),  # ward pad: the T-342 bridge seat
		Vector2(0.0, -240.0),  # Highkeep city rect centre
		Vector2(100.0, -240.0),  # Highkeep rect interior
		Vector2(420.0, 0.0),  # Hollowed Crypt pad
		Vector2(0.0, 420.0),  # PvP arena pad
		Vector2(-420.0, 3.0),  # Ashmoor district pad
	]
	for p in flat_points:
		assert_eq(field.height(p.x, p.y), 0.0, "flat pad %s must be level" % p)


func test_walked_relief_is_gentle_but_real() -> void:
	# T-445 acceptance: the playable floor is no longer a dead-flat plane — the meadow rolls with
	# pastoral amplitude (visible rises/hollows, nothing alpine) and the King's Road dips through
	# a swale on the Highkeep approach.
	var field = TERRAIN_FIELD.new()
	var swale: float = field.height(0.0, -80.0)
	assert_lt(swale, -0.8, "the King's Road dips through the approach swale")
	assert_gt(swale, -2.5, "the swale stays a gentle dip, not a trench")
	var rolling := 0
	for p in [
		Vector2(150.0, 0.0), Vector2(0.0, 150.0), Vector2(-150.0, -60.0), Vector2(120.0, 90.0)
	]:
		if absf(field.height(p.x, p.y)) > 0.6:
			rolling += 1
	assert_gt(rolling, 1, "open meadow carries real rolling relief")


func test_riverbed_is_carved_below_the_water_plane() -> void:
	# T-445/T-441: the river runs in a cut bed ~0.5 m under the y=0.06 water plane — except at the
	# wall base and under the bridge piers, where the T-342 grade-0 seats are preserved.
	var field = TERRAIN_FIELD.new()
	assert_almost_eq(field.height(19.0, -126.0), -0.5, 0.01, "poor-ward reach runs in a cut bed")
	assert_almost_eq(field.height(23.0, -210.0), -0.5, 0.01, "city-side reach runs in a cut bed")
	assert_almost_eq(field.height(5.2, -109.0), 0.0, 0.001, "bridge piers keep their grade-0 seat")
	assert_almost_eq(field.height(19.0, -140.0), 0.0, 0.001, "wall base keeps its grade-0 seat")


func test_relief_exists_off_the_protected_pockets() -> void:
	# Away from the pads the ground carries real slope: the T-287 backdrop ridge and the T-309
	# mountain ring still frame the vale.
	var field = TERRAIN_FIELD.new()
	assert_gt(field.height(0.0, -380.0), 3.0, "backdrop ridge rises several metres")
	assert_gt(field.height(560.0, 0.0), 20.0, "mountain ring rises outside the clamp box")


# T-559: q_tut_01 sends every fresh player to loc_training_ring (14,10); the lake shore bowl had
# sunk the whole T-444 yard 0.03-0.41 m below the y=0.06 water plane and new players drowned at
# the tutorial's first objective. The ring centre, every NPC/mob anchor and the whole walked
# footprint must stay clearly above the water — this may never silently regress.
func test_training_yard_footprint_stays_above_the_water_plane() -> void:
	var field = TERRAIN_FIELD.new()
	var water_y := 0.06  # KEEP IN SYNC with water_view.gd / river_view.gd WATER_Y
	var anchors := [
		Vector2(14.0, 10.0),  # loc_training_ring — the q_tut_01 "reach" target
		Vector2(10.0, 10.0),  # mob_dummy — the practice dummy
		Vector2(16.0, 10.0),  # mob_training_effigy — the straw sparring effigy
		Vector2(12.5, 9.0),  # Drillmaster Hale's anchor
		Vector2(15.5, 11.5),  # Hale's far patrol waypoint
		Vector2(14.0, 7.0),  # Arcanist Loreth
		Vector2(16.0, 7.0),  # Cleric Ansa
		Vector2(14.0, 5.9),  # the open yard gate mouth (the town approach)
	]
	for a in anchors:
		assert_gt(field.height(a.x, a.y), water_y, "yard anchor %s must sit above the water" % a)
	# The whole walked footprint (x 7..18, z 5..13) is dry, not just the anchors.
	for xi in range(7, 19):
		for zi in range(5, 14):
			assert_gt(
				field.height(float(xi), float(zi)),
				water_y,
				"yard footprint (%d,%d) must sit above the water" % [xi, zi]
			)


func test_field_is_deterministic_across_instances() -> void:
	# The server builds its own instance from its own byte-identical copy; two fresh instances must
	# agree bit-for-bit, or client and server would stand on different ground.
	var a = TERRAIN_FIELD.new()
	var b = TERRAIN_FIELD.new()
	for p in [Vector2(37.0, -211.0), Vector2(-140.0, 90.0), Vector2(260.0, -300.0)]:
		assert_eq(a.height(p.x, p.y), b.height(p.x, p.y), "instances disagree at %s" % p)
