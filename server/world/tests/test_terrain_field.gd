extends GutTest

# T-327: the world server's byte-identical copy of the shared terrain-height field (canonical:
# client/scripts/world/terrain_field.gd, synced by scripts/check_shared_files_sync.sh). The server
# derives position.z (ground height) from it on every move — never from the wire. These fixtures
# are IDENTICAL to client/tests/test_terrain_field.gd: a green run on both sides is the runtime
# proof that client and server stand on the same ground. T-445 refreshed them for the walkable
# relief pass (rolling meadows, King's Road swale, carved riverbed, new flat pads).

const TERRAIN_FIELD := preload("res://scripts/terrain_field.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const TOKEN := "abcdef0123456789abcdef0123456789"  # gitleaks:allow — 32-char hex test token

const FIXTURES := [
	[0.0, 0.0, 0.0],
	[10.0, 5.0, 0.24],  # T-559 training-yard dry pad
	[50.0, -100.0, 0.272858],
	[150.0, 150.0, 0.117201],
	[-200.0, 120.0, 0.217118],
	[0.0, -380.0, 4.928226],
	[18.0, 22.0, -0.55],
	[300.0, -380.0, 5.007974],
	[560.0, 0.0, 33.340040],
	[-620.0, -620.0, 89.258334],
	[0.0, -80.0, -1.219954],
	[19.0, -126.0, -0.5],
	[150.0, 0.0, 2.297025],
	[0.0, 150.0, -1.713331],
]

# T-590 MIGRATION INVARIANT (make-or-break): a DENSE height grid captured from PRE-T-590 main —
# over the Wold feature circle (step 60) + the Ashmoor footprint (step 40). The region-dispatch
# refactor MUST reproduce every one of these to 1e-4: both shipped regions route to the same
# absolute legacy field, so the grid is byte-identical (proven: a pristine-vs-HEAD dump matched
# exactly). If a future edit changes the seeded terrain, THIS is the tripwire.
const GOLDEN_GRID := [
	[-330, -330, 0.229534],
	[-330, -270, -0.287533],
	[-330, -210, -0.348761],
	[-330, -150, 0.417907],
	[-330, -90, -0.658728],
	[-330, -30, 0.454614],
	[-330, 30, -1.407612],
	[-330, 90, 2.585457],
	[-330, 150, -0.517846],
	[-330, 210, 2.018275],
	[-330, 270, 0.350383],
	[-330, 330, -0.709458],
	[-270, -330, -0.455982],
	[-270, -270, 1.143222],
	[-270, -210, 1.643668],
	[-270, -150, 3.312800],
	[-270, -90, -0.007856],
	[-270, -30, -1.504796],
	[-270, 30, -0.124818],
	[-270, 90, -1.262850],
	[-270, 150, 0.801482],
	[-270, 210, 2.633390],
	[-270, 270, 0.600688],
	[-270, 330, 0.013733],
	[-210, -330, -0.647227],
	[-210, -270, -1.069412],
	[-210, -210, 0.150628],
	[-210, -150, 2.534046],
	[-210, -90, -1.172913],
	[-210, -30, 1.631008],
	[-210, 30, 1.848726],
	[-210, 90, -1.640681],
	[-210, 150, -0.782016],
	[-210, 210, 0.101842],
	[-210, 270, -0.013593],
	[-210, 330, 0.310272],
	[-150, -330, -0.174743],
	[-150, -270, -0.030481],
	[-150, -210, -0.705273],
	[-150, -150, -0.028357],
	[-150, -90, 2.312598],
	[-150, -30, -1.487922],
	[-150, 30, 0.881363],
	[-150, 90, -1.628593],
	[-150, 150, 1.474224],
	[-150, 210, 2.316174],
	[-150, 270, -0.333778],
	[-150, 330, -0.677403],
	[-90, -330, 0.000000],
	[-90, -270, 0.000000],
	[-90, -210, 0.000000],
	[-90, -150, 0.000000],
	[-90, -90, -0.253396],
	[-90, -30, 1.917928],
	[-90, 30, 0.345708],
	[-90, 90, -0.449524],
	[-90, 150, 2.646033],
	[-90, 210, 0.569945],
	[-90, 270, -0.791160],
	[-90, 330, 0.093085],
	[-30, -330, 0.000000],
	[-30, -270, 0.000000],
	[-30, -210, 0.000000],
	[-30, -150, 0.000000],
	[-30, -90, -0.826308],
	[-30, -30, 0.000000],
	[-30, 30, 0.000000],
	[-30, 90, 0.726538],
	[-30, 150, -1.949140],
	[-30, 210, 0.671343],
	[-30, 270, 0.537595],
	[-30, 330, -0.231063],
	[30, -330, 0.000000],
	[30, -270, 0.000000],
	[30, -210, 0.000000],
	[30, -150, 0.000000],
	[30, -90, -0.889748],
	[30, -30, 0.000000],
	[30, 30, -0.063288],
	[30, 90, -0.511191],
	[30, 150, -0.620407],
	[30, 210, 2.043602],
	[30, 270, -0.102234],
	[30, 330, -0.180392],
	[90, -330, 0.000000],
	[90, -270, 0.000000],
	[90, -210, 0.000000],
	[90, -150, 0.000000],
	[90, -90, 1.335377],
	[90, -30, -0.705810],
	[90, 30, -1.124645],
	[90, 90, 0.258904],
	[90, 150, 0.680263],
	[90, 210, 1.454192],
	[90, 270, -1.343439],
	[90, 330, -0.376503],
	[150, -330, 0.181497],
	[150, -270, -0.341796],
	[150, -210, 0.161838],
	[150, -150, -0.383139],
	[150, -90, 1.088472],
	[150, -30, 0.969519],
	[150, 30, -0.704859],
	[150, 90, -1.925917],
	[150, 150, 0.117201],
	[150, 210, 2.088587],
	[150, 270, -0.011086],
	[150, 330, -0.263341],
	[210, -330, -0.001275],
	[210, -270, -0.067436],
	[210, -210, 0.781829],
	[210, -150, -0.179408],
	[210, -90, -0.047800],
	[210, -30, -1.818803],
	[210, 30, 1.556637],
	[210, 90, -0.979159],
	[210, 150, 0.254948],
	[210, 210, -0.143014],
	[210, 270, 0.004626],
	[210, 330, 0.792564],
	[270, -330, 0.904424],
	[270, -270, 0.071412],
	[270, -210, -1.951262],
	[270, -150, -1.754560],
	[270, -90, 2.020236],
	[270, -30, -0.614920],
	[270, 30, 1.955131],
	[270, 90, -2.274539],
	[270, 150, 0.137953],
	[270, 210, 0.146697],
	[270, 270, -1.123490],
	[270, 330, -0.274391],
	[330, -330, -0.289744],
	[330, -270, 0.115642],
	[330, -210, -1.313817],
	[330, -150, 0.816858],
	[330, -90, -0.889096],
	[330, -30, 1.154377],
	[330, 30, -0.922092],
	[330, 90, -1.362461],
	[330, 150, -1.329645],
	[330, 210, -0.917698],
	[330, 270, 0.759256],
	[330, 330, -0.240805],
	[-480, -60, -0.388505],
	[-480, -20, 0.019204],
	[-480, 20, -0.035769],
	[-480, 60, 0.060233],
	[-440, -60, -0.039484],
	[-440, -20, 0.000000],
	[-440, 20, 0.000000],
	[-440, 60, 0.025068],
	[-400, -60, 0.965404],
	[-400, -20, 0.000000],
	[-400, 20, 0.000000],
	[-400, 60, 0.088591],
	[-360, -60, 1.057371],
	[-360, -20, -0.002424],
	[-360, 20, -0.079150],
	[-360, 60, -0.072066]
]


func test_server_samples_same_ground_as_client() -> void:
	var field = TERRAIN_FIELD.new()
	for f in FIXTURES:
		assert_almost_eq(field.height(f[0], f[1]), float(f[2]), 0.0001, "server ground drift")


func test_move_derived_height_is_zero_on_flat_pockets() -> void:
	# PlayerSessions.update_position derives pos.z from this field on every move. On the
	# protected-flat walked pockets it MUST read exactly 0.0 — the movement path is a strict no-op
	# today (no player floats/sinks; nothing new on the wire).
	var field = TERRAIN_FIELD.new()
	for p in [Vector2(0.0, 0.0), Vector2(0.0, -100.0), Vector2(0.0, -240.0), Vector2(20.0, -10.0)]:
		assert_eq(field.height(p.x, p.y), 0.0, "flat move-height at %s" % p)


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


func test_update_position_derives_ground_height() -> void:
	# End-to-end through the position authority: PlayerSessions.update_position records the DERIVED
	# ground z (0.0 on a flat pocket, real height on the T-287 ridge) — proving the movement path
	# plumbing is live, not a constant, and that a client-sent z would be overwritten.
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(1, TOKEN, "alice", Vector3.ZERO)
	PlayerSessions.update_position(1, Vector3(50.0, -30.0, 99.0))  # spoofed z=99 must be ignored
	var flat_pos: Vector3 = PlayerSessions.get_player(1).get("pos", Vector3.ONE)
	assert_eq(flat_pos.z, 0.0, "flat pocket: derived ground overrides any client-sent z")
	PlayerSessions.update_position(1, Vector3(0.0, -380.0, 0.0))  # the backdrop ridge
	var ridge_pos: Vector3 = PlayerSessions.get_player(1).get("pos", Vector3.ZERO)
	assert_almost_eq(ridge_pos.z, 4.928226, 0.0001, "ridge: ground height derived from (x, y)")
	PlayerSessions._reset_for_test()


func test_height_grid_regression_wold_and_ashmoor() -> void:
	# The migration invariant: region dispatch reproduces the pre-T-590 field EXACTLY over both
	# shipped regions (the Wold circle + the Ashmoor footprint). Values are literals from main.
	var field = TERRAIN_FIELD.new()
	for g in GOLDEN_GRID:
		assert_almost_eq(
			field.height(float(g[0]), float(g[1])),
			float(g[2]),
			0.0001,
			"T-590 grid drift at (%d,%d)" % [int(g[0]), int(g[1])]
		)


func test_ashmoor_sampler_swap_preserves_legacy_but_diverges_in_the_new_western_district() -> void:
	# T-593 first sampler swap: Ashmoor City now uses "ashmoor_flat". The migration invariant is
	# proven byte-identical elsewhere (GOLDEN_GRID over the whole x>=-500 area + the [-620,-620] rim
	# fixture). Here we prove the swap actually DIVERGED where it should: at world (-620,0) — in the
	# new western district opened by the ±550 clamp raise — the pre-swap wold_legacy field carried
	# the ~76 m T-309 mountain ring; "ashmoor_flat" replaces it with near-level era-2 urban ground.
	var field = TERRAIN_FIELD.new()
	assert_lt(
		absf(field.height(-620.0, 0.0)),
		2.0,
		"Ashmoor western district is urban-flat, not the wold's mountain ring"
	)
	# The dressed spike pad + the far mountain-rim corner are still byte-identical (rim = edge
	# dressing, hull = the shipped spike) — the swap can never perturb them.
	assert_eq(field.height(-420.0, 3.0), 0.0, "the dressed Ashmoor spike pad stays exactly flat")
	assert_almost_eq(
		field.height(-620.0, -620.0), 89.258334, 0.0001, "the Ashmoor-side world rim stays legacy"
	)


func test_greyrise_region_has_its_own_ground() -> void:
	# T-593 NEW era-3 region at (0,-1400): modern arrival flat + the Old Keep heritage rise at the
	# origin + a T-587 rising rim beyond its ±560 m clamp (never grey void).
	var field = TERRAIN_FIELD.new()
	assert_gt(field.height(0.0, -1400.0), 3.0, "the Old Keep heritage rise stands above the flat")
	assert_lt(
		absf(field.height(0.0, -1200.0)), 1.0, "the arrival district is near-level modern flat"
	)
	assert_gt(field.height(0.0, -2100.0), 20.0, "the rim rises past the clamp box (edge dressing)")


func test_region_dispatch_generalizes_to_a_new_region() -> void:
	# T-590 mechanism proof: a NEW toy region with its OWN sampler dispatches by nearest origin — a
	# point at the toy origin reads the toy's flat height, while a Wold point still reads the legacy
	# field. Proves height() is region-routed, not a single global formula, without moving the world.
	var field = TERRAIN_FIELD.new()
	var wold_before: float = field.height(0.0, -240.0)  # a known flat pad in the Wold
	field.register_region(Vector2(0.0, -900.0), "flat", {"base_y": 3.5})
	assert_almost_eq(field.height(0.0, -900.0), 3.5, 0.0001, "dispatches to the toy sampler")
	assert_almost_eq(field.height(-20.0, -905.0), 3.5, 0.0001, "toy region owns its neighbourhood")
	assert_almost_eq(
		field.height(0.0, -240.0),
		wold_before,
		0.0001,
		"the far Wold sample is untouched by the toy"
	)
