class_name NightSky
extends RefCounted

# T-404: the NIGHT SKY layer — moon, starfield, and moonlight. Immersion Run 7 headline: when the
# T-289 sun drops below the horizon the sky became a flat black VOID (no moon, no stars, no fill),
# so half of every day/night cycle read as a rendering bug rather than a place. T-084 delegated the
# night sky to T-137 and T-137 delegated it back — both shipped without building it. This closes it.
#
# Split like the T-408 EraAtmosphere template: the PURE fade math is static + unit-tested here (no
# engine state); WorldView owns the nodes and drives update() each _process tick off the same sun
# elevation the arc already computes. The visual layer (a camera-anchored transparent star/moon
# dome + a cool moonlight DirectionalLight3D) is built by build() and mutated by update().
#
# ZERO-REGRESSION CONTRACT (matches T-408): at DAY every night driver is exactly 0 — star_alpha,
# moon_alpha, moonlight_energy and the ambient lift all fall to 0 well before the sun clears the
# horizon, WorldView hides the dome and disables the moonlight, so era-0 daytime is byte-identical.
# The unit tests assert that. Every constant below is a data-tunable preset (no magic in the seams).

const NIGHT_SKY_SHADER := preload("res://shaders/night_sky.gdshader")

# --- Fade envelope (all data-tunable; keep night NIGHT, just not void) ---
# Sun-elevation window over which the night layer fades: fully out at/above SUN_NIGHT_HI (day),
# fully in at/below SUN_NIGHT_LO (dusk has crossed to night). Drives stars, moon, moonlight, lift.
const SUN_NIGHT_LO := -6.0
const SUN_NIGHT_HI := 8.0
# The moon only shows while its own disc is above the horizon (anti-solar arc).
const MOON_UP_LO := -2.0
const MOON_UP_HI := 6.0

const STAR_MAX_ALPHA := 1.0  # peak star opacity at deep clear night
const MOON_MAX_ALPHA := 1.0  # peak moon opacity when up on a clear night
# T-552 (owner: moonlit, NAVIGABLE dark): raised from 0.16 so the moon reads as a real cool key that
# shapes terrain/silhouettes with a soft shadow — still LOW, well under the T-298 warm lamp pool
# (base ~2.0), so lit streets pop and this stays a fill, not a daylight key (test caps it < 0.5).
const MOONLIGHT_MAX_ENERGY := 0.30
const MOONLIGHT_COLOR := Color(0.55, 0.66, 0.95)  # cool blue moonlight (~5000K-ish read)
# T-552: the night AMBIENT FLOOR. The env ambient is SKY-sourced, and the T-404 night sky dome is
# near-black, so scaling ambient_light_energy alone could never lift the void (black * energy is
# black). The fix pairs TWO levers, both 0-effect by day (night_factor == 0 -> byte-identical):
#   1) night_sky_contribution() swaps the ambient blend from the black sky toward this flat cool
#      moonlit color at night, so the floor lands on real colour instead of the void, and
#   2) NIGHT_AMBIENT_LIFT adds a small energy top-up on that colour.
# Together they keep ground + ~30m silhouettes (e.g. Highkeep) readable on a clear, even moonless,
# night while staying dark/atmospheric. All tunable — the owner row keeps these values in play.
#
# T-579 (play-agent portal #38): a live walk at AVALON_FREEZE_DAY=0.0 (elev_deg 0.0 — the dusk/night
# threshold the arc crosses at day_t 0, see FREEZE_ZERO_ELEV_DEG below) still read "near-pitch-black
# underfoot" even with the T-552 floor, because night_factor at that exact elevation is only ~0.61
# (the fade window is still 40% short of full night), so the T-552 constants only landed at ~40% of
# their already-modest strength. Raised the SAME two levers again, further, so the ground clears a
# walkable floor well before the fade finishes, not just at deep midnight:
#   NIGHT_AMBIENT_COLOR (0.17, 0.22, 0.38) -> (0.30, 0.36, 0.55) — brighter, same cool cast (b>g>r)
#   NIGHT_AMBIENT_LIFT   0.10 -> 0.28 — the energy top-up nearly tripled
#   NIGHT_SKY_CONTRIB_MIN 0.20 -> 0.10 — deep night leans harder on the flat floor colour, less on
#     the still-near-black sky term
# Net effect at the portal's exact repro point (elev_deg 0.0, era 0, clear): night_ambient() lift
# 0.061 -> 0.170 (~2.8x) and night_sky_contribution() (share of ambient still coming from the black
# sky) 0.515 -> 0.454 (majority now the flat floor colour, was a bare majority-sky before). At full
# deep night the floor is brighter still (by design — this is a floor that ramps in, not a fixed
# add) while staying well under daytime ambient. Kept conservative: still dark, still cool-toned,
# not daylight — a screenshot verifies the actual look before deploy (values are data-tunable).
const NIGHT_AMBIENT_COLOR := Color(0.30, 0.36, 0.55)  # desaturated cool moonlit blue
const NIGHT_AMBIENT_LIFT := 0.28
# Deep-night ambient_light_sky_contribution: 1.0 by day (pure sky, byte-identical) fading to this at
# full night, where most of the ambient comes from NIGHT_AMBIENT_COLOR instead of the black sky.
const NIGHT_SKY_CONTRIB_MIN := 0.10
# T-579: the exact sun elevation AVALON_FREEZE_DAY=0.0 pins (world_view.gd: arc = sin(day_t*TAU),
# elev_deg = SUN_ELEV_PEAK_DEG*arc; at day_t 0.0, arc is 0.0 -> elev_deg 0.0). This is the portal's
# night-QA reproduction point — NOT deep midnight, it is the dusk/night threshold itself, which is
# exactly why the pre-T-579 floor read darker than intended (night_factor here is well under 1.0).
const FREEZE_ZERO_ELEV_DEG := 0.0
# T-579 regression floor: night_ambient() at FREEZE_ZERO_ELEV_DEG must clear this minimum so a
# future tuning pass can't silently walk the floor back down toward the pre-T-579 "can't see your
# feet" void (was ~0.061 before this ticket; comfortable margin under the new ~0.170).
const GROUND_FILL_MIN_AT_FREEZE_ZERO := 0.15
# T-579 regression ceiling: ambient_light_sky_contribution at FREEZE_ZERO_ELEV_DEG must drop below
# this so the flat moonlit floor colour is the MAJORITY contributor, not the still-dark sky term
# (was ~0.515 — sky-majority — before this ticket).
const SKY_CONTRIB_MAX_AT_FREEZE_ZERO := 0.5

# How overcast (T-085 darkness) suppresses each layer — clouds/haze hide the stars first.
const STAR_DARKNESS_MUTE := 1.0  # full overcast fully hides stars (ticket assertion 4)
const MOON_DARKNESS_MUTE := 0.6
const MOONLIGHT_DARKNESS_MUTE := 0.5

# How the era blend (0 home .. 1 Ashmoor) mutes each layer — Ashmoor's coal smog dims the sky.
# COMPOSES with T-408's existing blend factor (WorldView passes _era_blend straight through), it is
# not hardcoded per-zone: a partial crossing mutes partially; muting never fully kills the sky.
const ERA_STAR_MUTE := 0.7
const ERA_MOON_MUTE := 0.6
const ERA_MOONLIGHT_MUTE := 0.5
const ERA_AMBIENT_MUTE := 0.4

# Dome geometry — big enough that near terrain/buildings occlude the horizon stars (realistic) but
# well inside the camera far plane; centred on the camera every frame (translation only).
const DOME_RADIUS := 1000.0
const MOON_SIZE := 0.05
const MOON_HALO := 60.0
const STAR_DENSITY := 0.035

# Engine-half state (built by build(), driven by update(); the static math above needs none of it).
var dome: MeshInstance3D = null
var moonlight: DirectionalLight3D = null
var _mat: ShaderMaterial = null


# 0..1 how deep into night we are, off the sun elevation (shared idiom with the T-298 lamp fade).
static func night_factor(sun_elev_deg: float) -> float:
	return clampf(1.0 - smoothstep(SUN_NIGHT_LO, SUN_NIGHT_HI, sun_elev_deg), 0.0, 1.0)


# 0..1 how far the moon disc is above the horizon (its own anti-solar arc elevation).
static func moon_up_factor(moon_elev_deg: float) -> float:
	return clampf(smoothstep(MOON_UP_LO, MOON_UP_HI, moon_elev_deg), 0.0, 1.0)


static func _era_mute(era_blend: float, strength: float) -> float:
	return 1.0 - strength * clampf(era_blend, 0.0, 1.0)


# Star opacity: fades in at night, out under overcast haze, muted (not killed) by the era smog.
static func star_alpha(sun_elev_deg: float, darkness: float, era_blend: float) -> float:
	return (
		STAR_MAX_ALPHA
		* night_factor(sun_elev_deg)
		* (1.0 - STAR_DARKNESS_MUTE * clampf(darkness, 0.0, 1.0))
		* _era_mute(era_blend, ERA_STAR_MUTE)
	)


# Moon opacity: night AND above-horizon; softly dimmed by overcast and the era smog.
static func moon_alpha(
	sun_elev_deg: float, moon_elev_deg: float, darkness: float, era_blend: float
) -> float:
	return (
		MOON_MAX_ALPHA
		* night_factor(sun_elev_deg)
		* moon_up_factor(moon_elev_deg)
		* (1.0 - MOON_DARKNESS_MUTE * clampf(darkness, 0.0, 1.0))
		* _era_mute(era_blend, ERA_MOON_MUTE)
	)


# Cool moonlight directional energy — the "shapes read" fill; stays LOW so lamp pools still pop.
static func moonlight_energy(
	sun_elev_deg: float, moon_elev_deg: float, darkness: float, era_blend: float
) -> float:
	return (
		MOONLIGHT_MAX_ENERGY
		* night_factor(sun_elev_deg)
		* moon_up_factor(moon_elev_deg)
		* (1.0 - MOONLIGHT_DARKNESS_MUTE * clampf(darkness, 0.0, 1.0))
		* _era_mute(era_blend, ERA_MOONLIGHT_MUTE)
	)


# A small cool ambient floor added to env energy at night (0 by day -> byte-identical daytime).
static func night_ambient(sun_elev_deg: float, era_blend: float) -> float:
	return NIGHT_AMBIENT_LIFT * night_factor(sun_elev_deg) * _era_mute(era_blend, ERA_AMBIENT_MUTE)


# ambient_light_sky_contribution for the env: 1.0 by day (pure sky ambient -> byte-identical) fading
# to NIGHT_SKY_CONTRIB_MIN at deep night, so the flat NIGHT_AMBIENT_COLOR carries the floor while
# the near-black sky no longer swallows it. era-independent: by day night_factor==0 -> exactly 1.0.
static func night_sky_contribution(sun_elev_deg: float) -> float:
	return lerpf(1.0, NIGHT_SKY_CONTRIB_MIN, night_factor(sun_elev_deg))


# World-space unit direction TO a celestial body at (elevation, compass azimuth). Convention per
# T-289 / world-conventions.md: az 90=east(+X), 180=south(+Z), 270=west(-X), 0=north(-Z).
static func celestial_direction(elev_deg: float, az_deg: float) -> Vector3:
	var e := deg_to_rad(elev_deg)
	var a := deg_to_rad(az_deg)
	return Vector3(cos(e) * sin(a), sin(e), -cos(e) * cos(a))


# ---- Engine half: node construction + per-frame drive (headless-safe; math above is tested) ----


# Build the star/moon dome + the moonlight directional and parent them under `parent` (WorldView).
func build(parent: Node3D) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = DOME_RADIUS
	sphere.height = DOME_RADIUS * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	_mat = ShaderMaterial.new()
	_mat.shader = NIGHT_SKY_SHADER
	_mat.set_shader_parameter("star_density", STAR_DENSITY)
	_mat.set_shader_parameter("moon_size", MOON_SIZE)
	_mat.set_shader_parameter("moon_halo", MOON_HALO)
	dome = MeshInstance3D.new()
	dome.name = "NightSkyDome"
	dome.mesh = sphere
	dome.material_override = _mat
	dome.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	dome.extra_cull_margin = DOME_RADIUS  # always in-frustum; the camera sits at its centre
	dome.visible = false  # hidden until night lifts the alphas (byte-identical day)
	parent.add_child(dome)

	moonlight = DirectionalLight3D.new()
	moonlight.name = "Moonlight"
	moonlight.light_color = MOONLIGHT_COLOR
	moonlight.light_energy = 0.0
	# T-552: soft moon shadows so silhouettes (roofs, walls, the Highkeep mass) read at distance
	# without going hard-edged like the sun. Only pays the pass while the moon is up (visible toggles
	# off by day / when the moon is below the horizon), so daytime cost is unchanged.
	moonlight.shadow_enabled = true
	moonlight.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	moonlight.directional_shadow_max_distance = 150.0
	moonlight.shadow_blur = 2.5
	moonlight.shadow_bias = 0.06
	moonlight.visible = false
	parent.add_child(moonlight)


# Drive the layer for a frame. `sun_elev_deg` from the T-289 arc; `moon_elev_deg`/`moon_az_deg`
# from the anti-solar arc; `darkness` the T-085 overcast; `era_blend` the T-408 crossing;
# `cam_pos` anchors the dome (translation only). WorldView reads night_ambient() for the env lift.
func update(
	sun_elev_deg: float,
	moon_elev_deg: float,
	moon_az_deg: float,
	darkness: float,
	era_blend: float,
	cam_pos: Vector3
) -> void:
	if dome == null or moonlight == null:
		return
	var sa := star_alpha(sun_elev_deg, darkness, era_blend)
	var ma := moon_alpha(sun_elev_deg, moon_elev_deg, darkness, era_blend)
	var visible := sa > 0.002 or ma > 0.002
	dome.visible = visible
	if visible:
		dome.global_position = cam_pos
		_mat.set_shader_parameter("star_alpha", sa)
		_mat.set_shader_parameter("moon_alpha", ma)
		_mat.set_shader_parameter("moon_dir", celestial_direction(moon_elev_deg, moon_az_deg))

	var me := moonlight_energy(sun_elev_deg, moon_elev_deg, darkness, era_blend)
	moonlight.visible = me > 0.001
	if moonlight.visible:
		# Shine FROM the moon: mirror the sun's basis mapping (pitch=-elev, yaw=180-azimuth, T-289).
		moonlight.rotation_degrees.x = -moon_elev_deg
		moonlight.rotation_degrees.y = 180.0 - moon_az_deg
		moonlight.light_energy = me
