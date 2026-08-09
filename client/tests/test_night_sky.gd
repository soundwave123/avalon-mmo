extends GutTest

# T-404: the night sky fade math (NightSky, the pure half of the moon/starfield/moonlight layer).
# The load-bearing contract mirrors T-408: ZERO REGRESSION by day. At the daytime sun elevation
# every night driver is exactly 0, so the era-0 daytime frame is byte-identical to before this
# ticket. These tests assert that, plus the dusk fade-in, the dawn fade-out (no hard pop), the
# overcast suppression, the era-smog muting composition, and the anti-solar moon direction.

const NIGHT_SKY = preload("res://scripts/world/night_sky.gd")

# The daytime sun elevation world_view pins (day_t 0.34 -> ~46deg) and a deep-night elevation.
const DAY_ELEV := 46.0
const NIGHT_SUN_ELEV := -40.0  # sun well below the horizon
const NIGHT_MOON_ELEV := 45.0  # moon high (anti-solar arc peaks at midnight)


# --- Zero-regression: every night driver is 0 at day, so daytime rendering is byte-identical. ---
func test_daytime_is_byte_identical_all_drivers_zero() -> void:
	assert_eq(NIGHT_SKY.star_alpha(DAY_ELEV, 0.0, 0.0), 0.0, "no stars by day")
	assert_eq(NIGHT_SKY.moon_alpha(DAY_ELEV, NIGHT_MOON_ELEV, 0.0, 0.0), 0.0, "no moon by day")
	assert_eq(
		NIGHT_SKY.moonlight_energy(DAY_ELEV, NIGHT_MOON_ELEV, 0.0, 0.0), 0.0, "no moonlight by day"
	)
	assert_eq(NIGHT_SKY.night_ambient(DAY_ELEV, 0.0), 0.0, "no ambient lift by day")
	# T-552: the ambient blend stays pure-sky by day, so the flat night colour never touches daytime.
	assert_eq(
		NIGHT_SKY.night_sky_contribution(DAY_ELEV), 1.0, "day ambient is pure sky (byte-identical)"
	)


func test_night_factor_is_zero_by_day_and_one_deep_night() -> void:
	assert_eq(NIGHT_SKY.night_factor(DAY_ELEV), 0.0, "day is full daylight")
	assert_eq(NIGHT_SKY.night_factor(NIGHT_SUN_ELEV), 1.0, "deep night is full night")


# --- Night actually lights up (the void is gone). ---
func test_clear_night_shows_stars_moon_moonlight() -> void:
	assert_gt(NIGHT_SKY.star_alpha(NIGHT_SUN_ELEV, 0.0, 0.0), 0.5, "stars visible at night")
	assert_gt(
		NIGHT_SKY.moon_alpha(NIGHT_SUN_ELEV, NIGHT_MOON_ELEV, 0.0, 0.0),
		0.5,
		"moon visible at night"
	)
	assert_gt(
		NIGHT_SKY.moonlight_energy(NIGHT_SUN_ELEV, NIGHT_MOON_ELEV, 0.0, 0.0),
		0.0,
		"moonlight fills at night"
	)
	assert_gt(NIGHT_SKY.night_ambient(NIGHT_SUN_ELEV, 0.0), 0.0, "cool ambient floor at night")


# Moonlight must stay LOW — well under the T-298 street-lamp warm pool (base ~2.0) so lamps pop.
func test_moonlight_stays_under_the_lamp_pool() -> void:
	var me := NIGHT_SKY.moonlight_energy(NIGHT_SUN_ELEV, NIGHT_MOON_ELEV, 0.0, 0.0)
	assert_lt(me, 0.5, "moonlight is a faint fill, not a key")


# --- T-552: the ambient FLOOR makes night NAVIGABLE (not a black void), and reads cool. ---
func test_night_ambient_floor_lands_on_a_cool_colour() -> void:
	# By day the ambient is pure sky; at night the blend swaps toward the flat cool floor so the
	# (black) night sky can no longer swallow the ambient energy to zero.
	var night := NIGHT_SKY.night_sky_contribution(NIGHT_SUN_ELEV)
	assert_lt(night, 1.0, "night swaps the ambient toward the flat cool floor (sky is black)")
	assert_gt(night, 0.0, "but keeps a whisper of sky in the blend")
	# The floor colour is a cool moonlit blue (blue dominant, and non-black so it actually lifts).
	var c: Color = NIGHT_SKY.NIGHT_AMBIENT_COLOR
	assert_gt(c.b, c.r, "the moonlit ambient reads cool (blue over red)")
	assert_gt(c.b, 0.1, "the floor colour is non-black so geometry stays readable")


# The floor + moonlight are a floor-then-fade envelope: readable across dusk with no hard pop.
func test_night_sky_contribution_fades_monotone_into_night() -> void:
	var prev := -1.0
	for i in range(41):
		# march from day down to deep night; contribution must only ever drop (toward the flat floor)
		var elev := lerpf(DAY_ELEV, NIGHT_SUN_ELEV, float(i) / 40.0)
		var c := NIGHT_SKY.night_sky_contribution(elev)
		if prev >= 0.0:
			assert_true(
				c <= prev + 1e-6, "ambient blend never jumps back toward sky (elev %.1f)" % elev
			)
		prev = c
	assert_almost_eq(
		NIGHT_SKY.night_sky_contribution(NIGHT_SUN_ELEV),
		NIGHT_SKY.NIGHT_SKY_CONTRIB_MIN,
		0.001,
		"deep night settles at the flat-floor minimum"
	)


# --- Dawn fade-out is monotone (no hard pop) as the sun climbs from night to day. ---
func test_dawn_star_fade_is_monotone_no_pop() -> void:
	var prev := 2.0
	for i in range(41):
		var elev := lerpf(NIGHT_SUN_ELEV, DAY_ELEV, float(i) / 40.0)
		var sa := NIGHT_SKY.star_alpha(elev, 0.0, 0.0)
		assert_true(sa <= prev + 1e-6, "stars never brighten as dawn breaks (elev %.1f)" % elev)
		prev = sa
	assert_eq(NIGHT_SKY.star_alpha(DAY_ELEV, 0.0, 0.0), 0.0, "fully faded by day")


# --- Overcast (T-085 darkness) suppresses the stars behind the haze (ticket assertion 4). ---
func test_overcast_suppresses_stars() -> void:
	var clear := NIGHT_SKY.star_alpha(NIGHT_SUN_ELEV, 0.0, 0.0)
	var hazy := NIGHT_SKY.star_alpha(NIGHT_SUN_ELEV, 0.6, 0.0)
	assert_lt(hazy, clear, "haze dims the stars")
	assert_eq(NIGHT_SKY.star_alpha(NIGHT_SUN_ELEV, 1.0, 0.0), 0.0, "full overcast hides them")


# --- Era-smog muting COMPOSES with the T-408 blend (partial crossing = partial mute). ---
func test_era_smog_mutes_but_does_not_kill_the_night_sky() -> void:
	var home_star := NIGHT_SKY.star_alpha(NIGHT_SUN_ELEV, 0.0, 0.0)
	var ashmoor_star := NIGHT_SKY.star_alpha(NIGHT_SUN_ELEV, 0.0, 1.0)
	assert_lt(ashmoor_star, home_star, "Ashmoor smog mutes the stars")
	assert_gt(ashmoor_star, 0.0, "but does not kill them entirely")
	# a partial crossing sits strictly between home and full-era
	var half := NIGHT_SKY.star_alpha(NIGHT_SUN_ELEV, 0.0, 0.5)
	assert_gt(half, ashmoor_star, "half-crossing less muted than full")
	assert_lt(half, home_star, "half-crossing more muted than home")
	# same composition holds for the moon and moonlight
	assert_lt(
		NIGHT_SKY.moon_alpha(NIGHT_SUN_ELEV, NIGHT_MOON_ELEV, 0.0, 1.0),
		NIGHT_SKY.moon_alpha(NIGHT_SUN_ELEV, NIGHT_MOON_ELEV, 0.0, 0.0),
		"era mutes the moon"
	)
	assert_lt(
		NIGHT_SKY.moonlight_energy(NIGHT_SUN_ELEV, NIGHT_MOON_ELEV, 0.0, 1.0),
		NIGHT_SKY.moonlight_energy(NIGHT_SUN_ELEV, NIGHT_MOON_ELEV, 0.0, 0.0),
		"era mutes the moonlight"
	)


# --- T-579 (portal #38): the AVALON_FREEZE_DAY=0.0 repro point must clear a walkable floor. -------
# day_t=0.0 -> elev_deg 0.0 (NIGHT_SKY.FREEZE_ZERO_ELEV_DEG) per the world_view.gd arc math — the
# dusk/night threshold itself, NOT deep midnight. A numeric regression guard so a future tuning pass
# can't silently walk the floor back down toward "can't see your feet" without a test failing.
func test_freeze_day_zero_ground_fill_clears_the_moonlit_floor() -> void:
	var lift := NIGHT_SKY.night_ambient(NIGHT_SKY.FREEZE_ZERO_ELEV_DEG, 0.0)
	assert_gte(
		lift,
		NIGHT_SKY.GROUND_FILL_MIN_AT_FREEZE_ZERO,
		"the ambient lift at the portal's night repro point must clear the T-579 floor"
	)
	var contrib := NIGHT_SKY.night_sky_contribution(NIGHT_SKY.FREEZE_ZERO_ELEV_DEG)
	assert_lte(
		contrib,
		NIGHT_SKY.SKY_CONTRIB_MAX_AT_FREEZE_ZERO,
		"the flat moonlit floor colour must be the majority contributor, not the still-dark sky"
	)


# --- The moon hides while below the horizon and shows once it has risen (anti-solar arc). ---
func test_moon_hidden_below_horizon() -> void:
	assert_eq(NIGHT_SKY.moon_alpha(NIGHT_SUN_ELEV, -20.0, 0.0, 0.0), 0.0, "no moon when it is down")
	assert_gt(NIGHT_SKY.moon_alpha(NIGHT_SUN_ELEV, 30.0, 0.0, 0.0), 0.0, "moon shows once risen")


# --- Celestial direction matches the T-289 world convention (+X east, +Z south, up +Y). ---
func test_celestial_direction_compass_convention() -> void:
	# due east on the horizon
	var east := NIGHT_SKY.celestial_direction(0.0, 90.0)
	assert_almost_eq(east.x, 1.0, 0.001, "az 90 -> +X east")
	assert_almost_eq(east.y, 0.0, 0.001, "horizon -> y 0")
	assert_almost_eq(east.z, 0.0, 0.001, "az 90 -> z 0")
	# due south on the horizon
	var south := NIGHT_SKY.celestial_direction(0.0, 180.0)
	assert_almost_eq(south.z, 1.0, 0.001, "az 180 -> +Z south")
	# straight overhead
	var up := NIGHT_SKY.celestial_direction(90.0, 180.0)
	assert_almost_eq(up.y, 1.0, 0.001, "elev 90 -> +Y up")
