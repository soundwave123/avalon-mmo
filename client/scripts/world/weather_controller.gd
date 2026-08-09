class_name WeatherController
extends RefCounted

# T-085: runtime driver turning the pure WeatherState cycle into a live client-local sky. Extracted
# from world_view.gd (at the 1000-line gdlint cap) so the weather runtime lives in one place: it
# owns the seeded cycle + gust clock and modulates the grass sway materials it is handed, while
# world_view keeps the node-side look dimming (it folds into the T-289 sun-arc block). AVALON_
# WEATHER pins a phase for a deterministic QA sky. Client-local only — see weather_state.gd.

const WeatherStateT := preload("res://scripts/world/weather_state.gd")

# Grass sway shader base wind_strength (its shader default is 0.11); a gust pulse swells it by up to
# +GRASS_GUST_AMP in calm weather and +RAIN_GUST_AMP when a storm drives the meadow harder.
const GRASS_BASE_WIND := 0.11
const GRASS_GUST_AMP := 0.08
const RAIN_GUST_AMP := 0.16

var _rng: RandomNumberGenerator = null
var _state: Dictionary = {}
var _clock := 0.0  # accumulated seconds for the gust pulse (independent of the sun's day_t)
var _forced := -1  # AVALON_WEATHER pins a phase for QA; -1 = run the cycle
var _foliage_mats: Array[ShaderMaterial] = []


# `foliage_mats` are the shared grass sway materials whose wind_strength the gust drives.
func setup(foliage_mats: Array[ShaderMaterial]) -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = 20260703  # deterministic client-local cycle (replayable)
	_state = WeatherStateT.new_state()
	_foliage_mats = foliage_mats
	match OS.get_environment("AVALON_WEATHER").to_lower():
		"clear":
			_forced = WeatherStateT.PHASE_CLEAR
		"overcast":
			_forced = WeatherStateT.PHASE_OVERCAST
		"rain":
			_forced = WeatherStateT.PHASE_RAIN
		_:
			_forced = -1


# Advance one tick: roll the cycle (or hold the QA-forced phase), pulse the foliage gust, and
# return {darkness: 0..1 overcast dimming, rain: bool particle-want}. The caller applies the rain
# want through its own T-187 suppression path and folds `darkness` into the sun-arc look.
func tick(delta: float) -> Dictionary:
	_clock += delta
	var darkness := 0.0
	var rain := false
	if _forced >= 0:
		darkness = float(WeatherStateT._DARK[_forced])
		rain = _forced == WeatherStateT.PHASE_RAIN
	elif _rng != null:
		_state = WeatherStateT.tick(_state, delta, _rng)
		darkness = float(_state.get("darkness", 0.0))
		rain = bool(_state.get("rain", false))
	_apply_foliage_gust(darkness)
	return {"darkness": darkness, "rain": rain}


# Swell/lull the grass sway wind_strength (harder while raining). One set_shader_parameter per
# shared grass material, no per-frame allocation (T-210).
func _apply_foliage_gust(darkness: float) -> void:
	if _foliage_mats.is_empty():
		return
	var pulse := WeatherStateT.gust(_clock)
	var amp := lerpf(GRASS_GUST_AMP, RAIN_GUST_AMP, clampf(darkness, 0.0, 1.0))
	var strength := WeatherStateT.wind_strength(GRASS_BASE_WIND, amp, pulse)
	for m in _foliage_mats:
		m.set_shader_parameter("wind_strength", strength)
