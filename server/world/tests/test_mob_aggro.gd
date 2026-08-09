# T-402: level-relative aggro radius — pure-module math. No OS time, no engine loop, no network.
# Proves the WoW-shape reach: same-level base, per-level shrink, floor, growth cap, gray cutoff,
# leash ceiling, and the squared-distance helper the hot path uses.

extends GutTest

const _AGG = preload("res://scripts/combat/mob_aggro.gd")
const _SC = preload("res://scripts/server_config.gd")

const _BASE := 18.0  # a street-tier same-level reach


func test_same_level_returns_base() -> void:
	assert_almost_eq(
		_AGG.effective_radius(_BASE, 22, 22), _BASE, 0.001, "at equal level the reach IS the base"
	)


func test_out_leveling_shrinks_reach() -> void:
	# Player 4 levels above the mob: base - 1.75*4 = 18 - 7 = 11.
	var r := _AGG.effective_radius(_BASE, 20, 24)
	assert_almost_eq(r, 11.0, 0.001, "reach shrinks by PER_LEVEL_SHRINK per level out-leveled")
	# Monotonic: more out-leveling never widens the reach.
	assert_lt(
		_AGG.effective_radius(_BASE, 20, 26),
		_AGG.effective_radius(_BASE, 20, 24),
		"the further you out-level, the smaller the reach",
	)


func test_reach_never_below_floor() -> void:
	# 7 levels over: 18 - 12.25 = 5.75; 8+ is gray (tested separately). Floor clamps a small base up.
	assert_gte(
		_AGG.effective_radius(_BASE, 20, 27),
		_SC.AGGRO_FLOOR,
		"a non-gray mob never drops below floor"
	)
	assert_eq(
		_AGG.effective_radius(3.0, 20, 20),
		_SC.AGGRO_FLOOR,
		"a sub-floor base clamps UP to the floor"
	)


func test_under_leveling_grows_reach_but_caps_at_max() -> void:
	# Mob 6 levels ABOVE the player: base + 1.75*6 = 28.5, capped at AGGRO_MAX.
	var r := _AGG.effective_radius(_BASE, 26, 20)
	assert_eq(r, _SC.AGGRO_MAX, "a higher-level mob's reach grows but caps at AGGRO_MAX")


func test_gray_mob_never_aggros() -> void:
	# Exactly GRAY_DELTA over -> gray. Zero reach even though the raw formula would still be positive.
	var over := _SC.AGGRO_GRAY_DELTA
	assert_eq(
		_AGG.effective_radius(_BASE, 20, 20 + over),
		0.0,
		"a gray mob (>= GRAY_DELTA over) never aggros"
	)
	# One level short of gray is still live.
	assert_gt(
		_AGG.effective_radius(_BASE, 20, 20 + over - 1),
		0.0,
		"one below the gray cutoff still aggros"
	)


func test_leash_ceilings_the_reach() -> void:
	# A low-level player vs a much higher mob would grow to AGGRO_MAX, but a tight leash caps it lower
	# so the mob can't aggro a target it would evade off of next tick.
	assert_eq(
		_AGG.effective_radius(_BASE, 30, 20, 12.0),
		12.0,
		"the leash tether ceilings the effective reach below AGGRO_MAX",
	)


func test_squared_helper_matches_square_of_radius() -> void:
	var r := _AGG.effective_radius(_BASE, 22, 24)
	assert_almost_eq(
		_AGG.effective_radius_sq(_BASE, 22, 24),
		r * r,
		0.001,
		"the _sq helper is the square of the reach"
	)
	assert_eq(
		_AGG.effective_radius_sq(_BASE, 20, 40),
		0.0,
		"a gray mob's squared reach is 0 (fails any compare)"
	)


# T-402 live regression: _copy_mob runs every ai tick — a field it misses resets to the MobData
# default after tick ONE, which is invisible to every first-tick test (mob_level fell to 1 killing
# proximity aggro; xp fell to 0 killing every live mob-XP grant). Tick twice, assert persistence.
func test_second_tick_preserves_mob_level_and_xp() -> void:
	var loader = preload("res://scripts/combat/mob_loader.gd")
	var ai = preload("res://scripts/combat/mob_ai.gd")
	var tt = preload("res://scripts/combat/threat_table.gd").new()
	var mob = loader.load_from_file("res://data/mobs/syndicate_legbreaker.json", 2001)
	mob.position = Vector3(-420.0, 22.0, 0.0)
	mob.spawn_position = mob.position
	var rng := RandomNumberGenerator.new()
	var far := {}  # nobody near — pure idle/patrol ticks
	var r1 = ai.ai_tick(mob, far, tt, 100, rng)
	var r2 = ai.ai_tick(r1.new_mob, far, tt, 200, rng)
	assert_eq(int(r2.new_mob.mob_level), 22, "mob_level survives the copy on every tick")
	assert_gt(int(r2.new_mob.xp), 0, "xp survives the copy on every tick")
