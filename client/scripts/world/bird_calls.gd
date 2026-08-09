class_name BirdCalls
extends RefCounted

# T-733: the bird layer, rescheduled. Owner playtest 2026-08-08: "too many birds tweeting; needs to
# be more random and pleasant". The cause was structural, not a level: since T-305 the birds have
# been a LOOPING BED (amb_birdsong.wav on repeat, in AudioManager AND on the two treeline zones) —
# a 100% duty cycle replaying the same 9.6s recording all day. A loop IS a fixed interval.
#
# This replaces that loop with a SCHEDULER firing short one-shot calls out of the same asset (no new
# assets, per the ticket). Pure math + data, so the contract is headlessly unit-testable with a
# seeded RNG — the T-415 lesson is that an audio bug only visible live is one that ships. All of it
# is DATA (the AUDIO_ZONES idiom next door), so retuning after the walk-around is a data edit.

# --- density by time of day --------------------------------------------------
# day_t is the world day clock (WorldView._day_t, the value the ambience layer already reads —
# client-local today, per T-734). T-415 convention: NOON = 0.25, sunrise ~= 0.0, midnight = 0.75.
# `d` multiplies the call rate: 1.0 = the dawn chorus, 0.0 = the layer sleeps and the T-675 crickets
# own the night. Piecewise-linear, wrapping across midnight.
const DENSITY_BY_DAY_T: Array = [
	{"t": 0.00, "d": 1.00},  # sunrise — the dawn chorus, the one hour dense birdsong is CORRECT
	{"t": 0.04, "d": 1.00},
	{"t": 0.10, "d": 0.55},  # mid-morning: thinning out
	{"t": 0.18, "d": 0.28},
	{"t": 0.25, "d": 0.18},  # NOON — sparsest daylight hour (the owner's "constant midday chatter")
	{"t": 0.34, "d": 0.28},
	{"t": 0.42, "d": 0.55},  # evening chorus — real, but never as loud as dawn
	{"t": 0.47, "d": 0.45},
	{"t": 0.52, "d": 0.12},  # just past sunset: settling onto the roost
	{"t": 0.58, "d": 0.00},  # night — silent; crickets/owls (T-675) carry these hours
	{"t": 0.90, "d": 0.00},
	{"t": 0.95, "d": 0.35},  # pre-dawn: the first few wake before the sun
	{"t": 0.98, "d": 0.80},
]

# --- per-layer scheduling profiles -------------------------------------------
# mean_gap_s is the mean of the EXPONENTIAL component at density 1.0; the achieved mean gap for one
# voice is min_gap_s + mean_gap_s/density. At dawn that is ~23.5s per treeline (~2.6 calls/min);
# at noon (d=0.18) it is ~110s (~0.55 calls/min). Two treelines => ~5.1/min dawn, ~1.1/min noon.
const PROFILES: Dictionary = {
	"tree":
	{
		"mean_gap_s": 19.0,  # exponential mean at full (dawn) density
		"min_gap_s": 4.5,  # the FLOOR: one voice never re-calls faster than this
		"max_gap_s": 150.0,  # tail cap — a quiet patch, never dead air
		"burst_s": [1.1, 2.6],  # one call's length, drawn per call
		"pitch_band": [0.92, 1.09],  # +/- ~1.5 semitones — a different bird, not a chipmunk
		"gain_band_db": [-5.0, 0.0],  # per-call level, under the zone's base dB (never above)
		"attack_s": 0.18,  # fade in/out of the source slice so a call never clicks
		"release_s": 0.45,
		"source_len_s": 9.6,  # amb_birdsong.wav — calls read a random slice of it
		"silence_below": 0.04,  # density under this and the voice sleeps entirely
	},
}

# T-733 de-cluster: no two bird calls ANYWHERE may start within this of each other. Two emitters on
# the same beat read as one loud stereo stab instead of two birds in two trees.
const MIN_GLOBAL_GAP_S := 2.2

# The envelope floor — a call fades between this and 0 dB rather than snapping on/off.
const ENVELOPE_FLOOR_DB := -42.0

# --- the scheduler instance --------------------------------------------------
var rng := RandomNumberGenerator.new()
var min_global_gap_s := MIN_GLOBAL_GAP_S
var voices: Array = []  # [{key, profile, due_s, elapsed_s, burst_s, active}]
var since_last_call_s := 999.0  # born due: the first eligible voice may call immediately
var calls_fired := 0  # instrumentation — the density number the ticket wants measured
var calls_deferred := 0  # de-cluster hits (a call pushed off another call's beat)


# --- pure math (headlessly testable) -----------------------------------------
# Density multiplier at `day_t`, piecewise-linear over the curve, wrapping across midnight.
static func density_at(day_t: float, curve: Array = DENSITY_BY_DAY_T) -> float:
	if curve.is_empty():
		return 0.0
	var t := fposmod(day_t, 1.0)
	var prev: Dictionary = curve[curve.size() - 1]
	for k: Dictionary in curve:
		if t < float(k["t"]):
			return _lerp_key(prev, k, t)
		prev = k
	return _lerp_key(prev, curve[0], t)  # past the last key: wrap round to the first


static func _lerp_key(a: Dictionary, b: Dictionary, t: float) -> float:
	var span := fposmod(float(b["t"]) - float(a["t"]), 1.0)
	if span <= 0.0:
		return float(b["d"])
	var f := clampf(fposmod(t - float(a["t"]), 1.0) / span, 0.0, 1.0)
	return lerpf(float(a["d"]), float(b["d"]), f)


# T-733 the Poisson draw. `u` is a uniform in [0,1), INJECTED so a seeded RNG makes the schedule
# reproducible in tests. Inter-call times are a SHIFTED EXPONENTIAL: gaps bunch short and
# occasionally run long, like a real hedgerow. Uniform jitter around a period does not — the ear
# locks onto the period and hears a metronome, which is the bug. The floor is ADDED, not clamped:
# clamping piles probability mass on min_gap_s and hands the beat straight back.
static func next_gap_s(
	u: float, mean_gap_s: float, density: float, min_gap_s: float, max_gap_s: float
) -> float:
	var d := clampf(density, 0.0001, 4.0)
	var mean := maxf(0.01, mean_gap_s / d)  # sparser hours stretch the mean gap
	var draw := -log(1.0 - clampf(u, 0.0, 0.999999)) * mean
	return clampf(min_gap_s + draw, min_gap_s, maxf(min_gap_s, max_gap_s))


# Per-call amplitude envelope in dB (0 at sustain, ENVELOPE_FLOOR_DB at the edges) so a call fades
# in and out of the source slice instead of clicking on a hard start/stop.
static func envelope_db(
	elapsed_s: float, burst_s: float, attack_s: float, release_s: float
) -> float:
	if elapsed_s <= 0.0 or elapsed_s >= burst_s or burst_s <= 0.0:
		return ENVELOPE_FLOOR_DB
	var g := 1.0
	if attack_s > 0.0:
		g = minf(g, elapsed_s / attack_s)
	if release_s > 0.0:
		g = minf(g, (burst_s - elapsed_s) / release_s)
	return lerpf(ENVELOPE_FLOOR_DB, 0.0, clampf(g, 0.0, 1.0))


# T-733: the same curve as an attenuation for a continuous BED (the global AudioManager birdsong
# wash). One looping player can't be scheduled, so it is DIMMED by density instead.
static func bed_density_atten_db(density: float, full_dim_db: float) -> float:
	return (1.0 - clampf(density, 0.0, 1.0)) * full_dim_db


# Register one emitter with the scheduler. Voices are born with a partial gap so the treelines
# don't all open on the same frame at boot.
func add_voice(key: String, profile_name := "tree") -> void:
	var prof: Dictionary = PROFILES.get(profile_name, PROFILES["tree"])
	(
		voices
		. append(
			{
				"key": key,
				"profile": prof,
				"due_s": rng.randf_range(2.0, float(prof["mean_gap_s"])),
				"elapsed_s": 0.0,
				"burst_s": 0.0,
				"active": false,
			}
		)
	)


# Advance the schedule by `delta` at day-clock `day_t`. Returns the calls that START this tick:
# [{key, pitch, gain_db, burst_s, offset_s}] — playback is the caller's job, this stays pure-ish
# (RNG only) so it can be ticked thousands of times a second in a headless test.
func tick(delta: float, day_t: float) -> Array:
	var fired: Array = []
	since_last_call_s += delta
	var density := density_at(day_t)
	for v: Dictionary in voices:
		var prof: Dictionary = v["profile"]
		if bool(v["active"]):
			v["elapsed_s"] = float(v["elapsed_s"]) + delta
			if float(v["elapsed_s"]) >= float(v["burst_s"]):
				v["active"] = false
			continue  # a voice never overlaps itself
		if density < float(prof["silence_below"]):
			# Night: the layer sleeps. Hold the timer at the floor rather than banking a backlog of
			# overdue calls that would all dump out at sunrise.
			v["due_s"] = maxf(float(v["due_s"]), float(prof["min_gap_s"]))
			continue
		v["due_s"] = float(v["due_s"]) - delta
		if float(v["due_s"]) > 0.0:
			continue
		if since_last_call_s < min_global_gap_s:
			# De-cluster: push this voice past the global floor instead of dropping it, so the
			# other treeline's call gets air and this one still happens a beat later.
			v["due_s"] = min_global_gap_s - since_last_call_s
			calls_deferred += 1
			continue
		var burst: float = _band(prof["burst_s"])
		var head: float = maxf(0.0, float(prof["source_len_s"]) - burst)
		v["active"] = true
		v["elapsed_s"] = 0.0
		v["burst_s"] = burst
		v["due_s"] = _draw_gap(prof, density)
		since_last_call_s = 0.0
		calls_fired += 1
		(
			fired
			. append(
				{
					"key": str(v["key"]),
					"pitch": _band(prof["pitch_band"]),
					"gain_db": _band(prof["gain_band_db"]),
					"burst_s": burst,
					# a random read offset into the source: one 9.6s recording, never the same slice
					# twice — the single biggest win against "repetitive" without new assets.
					"offset_s": rng.randf_range(0.0, head),
				}
			)
		)
	return fired


func _band(band: Array) -> float:
	return rng.randf_range(float(band[0]), float(band[1]))


func _draw_gap(prof: Dictionary, density: float) -> float:
	return next_gap_s(
		rng.randf(),
		float(prof["mean_gap_s"]),
		density,
		float(prof["min_gap_s"]),
		float(prof["max_gap_s"])
	)
