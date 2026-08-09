class_name FootstepCadence
extends RefCounted

# T-737: decides WHEN a footfall lands and WHICH clip/pitch/level it uses. Playback is the
# caller's job, so this stays pure (RNG only) and can be ticked for simulated minutes in a
# headless test — the T-733 BirdCalls discipline.
#
# KEYING: distance, not time. The old T-111 hook was `footstep_if_due(340ms)` — a fixed wall-clock
# interval that ran at the same rate whether you strolled or sprinted, and played the SAME single
# sample every time. That is the machine-gun the ticket is about.
#
# Why not an animation call-method track (the ticket's first choice)? There is no AnimationTree in
# this client and no character .tscn: every rig is instantiated at runtime from a .glb whose
# .import is gitignored and regenerated, so there is nowhere durable to hang a method track. The
# ticket's stated fallback — cadence from movement speed — is also the house pattern.
#
# Distance-keying is strictly better than cadence-from-speed-as-a-rate: footfalls are emitted per
# METRE travelled, so speed scaling is automatic and exact (walking off a run decelerates the
# footfalls smoothly), and it stays honest when you are pushed into a wall — the callers feed
# MEASURED displacement, so a blocked player makes no sound.
#
# Anti-repetition has three independent levers, all measured in test_footstep_cadence.gd:
#   1. four sample variations per surface, drawn from a shuffle bag (never twice in a row, and
#      every variation used once per rotation),
#   2. per-footfall pitch jitter inside a gait-specific band,
#   3. stride-length jitter, so the interval is not a metronome (measured CV ~0.09; a metronome
#      is 0.0 and the T-733 bird Poisson is >0.5 — a gait belongs in between, and staying under
#      0.35 is what keeps it reading as walking rather than stumbling).

const GAIT_WALK := "walk"
const GAIT_RUN := "run"
const GAIT_MOUNT_WALK := "mount_walk"
const GAIT_MOUNT_GALLOP := "mount_gallop"

const SURFACES := TerrainSurface.SURFACES
const VARIATIONS := 4

# stride_m  = metres of travel per footfall (the whole cadence model)
# gain_db   = base level for the gait; ref_lo/ref_hi span the fine in-gait level trim
# pitch_band= per-footfall pitch jitter range
# mounted   = selects the mount clip set instead of the surface clip set
const GAITS := {
	GAIT_WALK:
	{
		"stride_m": 0.95,
		"gain_db": -17.0,
		"pitch_band": [0.94, 1.07],
		"ref_lo": 0.4,
		"ref_hi": 4.0,
		"mounted": false,
	},
	GAIT_RUN:
	{
		"stride_m": 1.90,
		"gain_db": -11.0,
		"pitch_band": [0.90, 1.04],
		"ref_lo": 4.0,
		"ref_hi": 6.5,
		"mounted": false,
	},
	# The shipped mounts are all the one ground gryphon rig (mount_visuals.gd) — a lion body, so
	# padded paw-falls, not iron-shod hooves and not wingbeats. A gallop is a fast 4-beat gait:
	# a shorter stride than a run relative to its speed, which lands ~4.7 falls/s at 9.6 m/s.
	GAIT_MOUNT_WALK:
	{
		"stride_m": 1.35,
		"gain_db": -14.0,
		"pitch_band": [0.93, 1.06],
		"ref_lo": 0.4,
		"ref_hi": 6.5,
		"mounted": true,
	},
	GAIT_MOUNT_GALLOP:
	{
		"stride_m": 2.05,
		"gain_db": -9.0,
		"pitch_band": [0.88, 1.02],
		"ref_lo": 6.5,
		"ref_hi": 10.0,
		"mounted": true,
	},
}

# Matches AnimStateMachine.RUN_THRESHOLD_MPS so the sound and the animation change gait together.
const RUN_THRESHOLD_MPS := 4.0
# Mounted walk is 4.0 m/s and mounted run is 9.6 m/s (PlayerMovement), so the split sits between.
const MOUNT_GALLOP_THRESHOLD_MPS := 6.5
# Below this you are shuffling, not walking — and it keeps physics jitter from ticking the cadence.
const MIN_SPEED_MPS := 0.4
# ...and above THIS you did not walk, you were moved. Callers derive speed from one frame's
# displacement, so a spawn snap, a respawn, a teleport or a position resync reads as hundreds of
# m/s for a single frame. Found by the T-415 audio-graph dump: every mob in the zone had grown a
# footstep emitter at spawn while standing perfectly still, including ones 120 m away. The fastest
# thing in the game is a galloping mount at 9.6 m/s, so anything past this is not locomotion.
const MAX_SPEED_MPS := 14.0
# +-15% on stride length. Small enough to still read as a gait, large enough to kill the metronome.
const STRIDE_JITTER := 0.15
# Fine level climb across a gait's speed span, on top of the coarse per-gait step.
const SPEED_TRIM_DB := 2.5
# A frame hitch must not dump its whole backlog of strides as one burst.
const MAX_STEPS_PER_TICK := 2
# On stopping, the accumulator is parked this far through a stride so moving off sounds prompt.
const RESUME_FRACTION := 0.6

var rng := RandomNumberGenerator.new()
var steps_fired := 0  # instrumentation the ticket records

var _dist_accum := 0.0  # metres travelled since the last footfall
var _next_stride := 0.0  # jittered stride length the next footfall is waiting on
var _gait := ""
var _bag: Array = []  # shuffle bag of variation indices
var _last_index := -1  # never repeat a clip back-to-back, even across bag refills


# Which gait a given speed reads as. Mounted has its own two-way split because a mount's walk
# (4.0 m/s) is already faster than a player's run threshold.
static func gait_for(speed_mps: float, is_mounted: bool) -> String:
	if is_mounted:
		return GAIT_MOUNT_GALLOP if speed_mps >= MOUNT_GALLOP_THRESHOLD_MPS else GAIT_MOUNT_WALK
	return GAIT_RUN if speed_mps >= RUN_THRESHOLD_MPS else GAIT_WALK


# The asset name for a gait/surface/variation. Mounted gaits ignore the surface: the gryphon's
# paw-fall is one set (giving it a per-surface set too would be 16 more samples for a mount that
# spends nearly all its time on open ground — noted in the ticket as a follow-up).
static func clip_for(gait: String, surface: String, index: int) -> String:
	var v := (index % VARIATIONS) + 1
	if bool(GAITS.get(gait, {}).get("mounted", false)):
		return "mount_step_%d" % v
	var s := surface if SURFACES.has(surface) else TerrainSurface.GRASS
	return "step_%s_%d" % [s, v]


# Level for a footfall: the coarse per-gait step (walk vs run is ~6 dB) plus a fine trim that
# rises across the gait's own speed span, so a sprint sits a touch above a jog.
static func gain_db(gait: String, speed_mps: float) -> float:
	var g: Dictionary = GAITS.get(gait, GAITS[GAIT_WALK])
	var lo := float(g["ref_lo"])
	var hi := float(g["ref_hi"])
	var t := 0.0 if hi <= lo else clampf((speed_mps - lo) / (hi - lo), 0.0, 1.0)
	return float(g["gain_db"]) + SPEED_TRIM_DB * t


# Advance the cadence. `speed_mps` should be MEASURED displacement/delta (not the input target),
# so walking into a wall is correctly silent. Returns the footfalls that land this tick — usually
# none or one — as {clip, gait, surface, index, pitch, gain_db}.
func tick(
	delta: float,
	speed_mps: float,
	is_mounted: bool,
	surface: String = TerrainSurface.GRASS,
	airborne: bool = false
) -> Array:
	if airborne or speed_mps < MIN_SPEED_MPS or speed_mps > MAX_SPEED_MPS:
		# Park near-due rather than resetting to zero, so moving off again sounds immediate
		# instead of swallowing the first stride.
		if _next_stride > 0.0:
			_dist_accum = minf(_dist_accum, _next_stride * RESUME_FRACTION)
		_gait = ""
		return []
	var gait := gait_for(speed_mps, is_mounted)
	if gait != _gait or _next_stride <= 0.0:
		_gait = gait
		_next_stride = _draw_stride(gait)
	_dist_accum += maxf(speed_mps, 0.0) * maxf(delta, 0.0)
	var out: Array = []
	while _dist_accum >= _next_stride and out.size() < MAX_STEPS_PER_TICK:
		_dist_accum -= _next_stride
		_next_stride = _draw_stride(gait)
		out.append(_emit(gait, surface, speed_mps))
	if out.size() >= MAX_STEPS_PER_TICK:
		# Drop the rest of the backlog: after a stall you want the gait to resume, not to hear
		# every stride the frozen frame owed you.
		_dist_accum = minf(_dist_accum, _next_stride)
	return out


func _draw_stride(gait: String) -> float:
	var base := float(GAITS.get(gait, GAITS[GAIT_WALK])["stride_m"])
	return base * (1.0 + rng.randf_range(-STRIDE_JITTER, STRIDE_JITTER))


func _emit(gait: String, surface: String, speed_mps: float) -> Dictionary:
	var idx := _next_index()
	var band: Array = GAITS[gait]["pitch_band"]
	steps_fired += 1
	return {
		"clip": clip_for(gait, surface, idx),
		"gait": gait,
		"surface": surface,
		"index": idx,
		"pitch": rng.randf_range(float(band[0]), float(band[1])),
		"gain_db": gain_db(gait, speed_mps),
	}


# Shuffle bag: every variation is used once per rotation (so none is starved and the ear never
# locks onto a two-sample alternation), and the first draw of a refilled bag is swapped away from
# the previous clip so the same sample can never land twice in a row across the seam.
func _next_index() -> int:
	if _bag.is_empty():
		for i in range(VARIATIONS):
			_bag.append(i)
		_shuffle_bag()
		if _bag.size() > 1 and _bag[0] == _last_index:
			var swap_to := 1 + (rng.randi() % (_bag.size() - 1))
			var tmp = _bag[0]
			_bag[0] = _bag[swap_to]
			_bag[swap_to] = tmp
	var idx: int = _bag.pop_front()
	_last_index = idx
	return idx


# Fisher-Yates against our OWN seeded rng — Array.shuffle() uses the global RNG and would break
# the seeded-reproducibility contract the tests rely on.
func _shuffle_bag() -> void:
	for i in range(_bag.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var tmp = _bag[i]
		_bag[i] = _bag[j]
		_bag[j] = tmp
