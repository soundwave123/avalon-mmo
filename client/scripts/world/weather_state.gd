class_name WeatherState
extends RefCounted

# T-085: pure ambient-weather tick — a seeded clear -> overcast -> rain cycle plus gust math.
# Mirrors npc_wander.gd's shape: no OS time, no globals, inputs never mutated; the caller injects
# `dt` and an `rng`, so the same seed replays the same weather (unit-testable, QA can pin it). This
# drives the CLIENT-LOCAL look only (rain/dimming/gust are cosmetic, NOT server truth). Server-
# authoritative synced weather is deferred to the world-server owner; when it lands it feeds this
# module the phase instead of the client rolling its own. The cycle ticks on `dt`, NOT the sun's
# day_t, so AVALON_FREEZE_DAY (frozen sun for QA) does not freeze weather; AVALON_WEATHER pins it.

const PHASE_CLEAR := 0
const PHASE_OVERCAST := 1
const PHASE_RAIN := 2

# Per-phase dwell time, seconds [min, max]. Clear dominates (a mostly-sunny meadow); overcast and
# rain are the weather that rolls through. Drawn once per phase entry from the injected rng.
const _DUR := {
	PHASE_CLEAR: Vector2(150.0, 360.0),
	PHASE_OVERCAST: Vector2(60.0, 150.0),
	PHASE_RAIN: Vector2(45.0, 120.0),
}

# Target "overcast darkness" 0..1 per phase — how far the sky/light dims below its clear value.
# world_view maps this onto fog + an ambient/sun energy multiplier that COOPERATES with the
# T-289 sun arc (it multiplies the arc's energy down, it does not fight the arc math).
const _DARK := {
	PHASE_CLEAR: 0.0,
	PHASE_OVERCAST: 0.5,
	PHASE_RAIN: 1.0,
}

# Seconds to cross-fade the look across a phase change, so weather rolls in/out instead of snapping.
const _RAMP := 12.0


# Opaque state. `phase`/`prev_phase` are PHASE_* ; `elapsed` counts seconds inside the current
# phase; `duration` is this phase's drawn dwell time; `since_change` counts seconds since the last
# transition (drives the ramp). Starts CLEAR (preserves the sunny-meadow default), fully settled.
static func new_state() -> Dictionary:
	return {
		"phase": PHASE_CLEAR,
		"prev_phase": PHASE_CLEAR,
		"elapsed": 0.0,
		"duration": 0.0,
		"since_change": _RAMP,  # start fully settled, no boot-time ramp
	}


# One tick. Advances the cycle by `dt` seconds; on dwell-time expiry it transitions to the next
# phase (weighted draw from the injected rng) and redraws a dwell time. Returns a NEW dict:
#   phase, prev_phase, elapsed, duration, since_change  (carry state, feed back next tick)
#   darkness       : float 0..1 — ramped overcast dimming target for the look
#   rain_intensity : float 0..1 — ramped rain-particle strength
#   rain           : bool        — whether rain particles should emit (intensity above epsilon)
static func tick(state: Dictionary, dt: float, rng) -> Dictionary:
	var phase: int = int(state.get("phase", PHASE_CLEAR))
	var prev_phase: int = int(state.get("prev_phase", phase))
	var elapsed: float = float(state.get("elapsed", 0.0)) + maxf(dt, 0.0)
	var duration: float = float(state.get("duration", 0.0))
	var since_change: float = float(state.get("since_change", _RAMP)) + maxf(dt, 0.0)

	if duration <= 0.0:
		# First tick after new_state(): draw the opening CLEAR dwell without a transition.
		duration = _draw_duration(phase, rng)
	elif elapsed >= duration:
		prev_phase = phase
		phase = _pick_next(phase, rng)
		duration = _draw_duration(phase, rng)
		elapsed = 0.0
		since_change = 0.0

	var blend := clampf(since_change / _RAMP, 0.0, 1.0)
	var darkness := lerpf(float(_DARK[prev_phase]), float(_DARK[phase]), blend)
	var prev_rain := 1.0 if prev_phase == PHASE_RAIN else 0.0
	var cur_rain := 1.0 if phase == PHASE_RAIN else 0.0
	var rain_intensity := lerpf(prev_rain, cur_rain, blend)

	return {
		"phase": phase,
		"prev_phase": prev_phase,
		"elapsed": elapsed,
		"duration": duration,
		"since_change": since_change,
		"darkness": darkness,
		"rain_intensity": rain_intensity,
		"rain": rain_intensity > 0.01,
	}


# A gust pulse in [0, 1]: two out-of-phase sine bands so the wind swells and lulls without an
# obvious single-period beat. Pure and deterministic — `t` is any accumulated seconds counter the
# caller supplies (world_view uses its own weather clock), NO rng and NO OS time, so it never
# allocates and replays identically. Callers map it onto a foliage wind_strength range.
static func gust(t: float) -> float:
	var g := 0.6 * sin(t * 0.7) + 0.4 * sin(t * 1.63 + 1.3)  # in [-1, 1]
	return clampf(0.5 + 0.5 * g, 0.0, 1.0)


# wind_strength for the foliage sway shader given the base sway, a gust amplitude, and the current
# gust pulse. Bounded in [base, base + amp] for pulse in [0, 1]; rain callers pass a larger amp.
static func wind_strength(base: float, amp: float, pulse: float) -> float:
	return base + amp * clampf(pulse, 0.0, 1.0)


static func _draw_duration(phase: int, rng) -> float:
	var r: Vector2 = _DUR[phase]
	return rng.randf_range(r.x, r.y)


# Weighted next-phase draw. Weather builds and clears through overcast: clear -> overcast, then
# overcast either breaks into rain or passes back to clear, and rain always tapers via overcast.
static func _pick_next(phase: int, rng) -> int:
	match phase:
		PHASE_CLEAR:
			return PHASE_OVERCAST
		PHASE_OVERCAST:
			return PHASE_RAIN if rng.randf() < 0.6 else PHASE_CLEAR
		PHASE_RAIN:
			return PHASE_OVERCAST
		_:
			return PHASE_CLEAR
