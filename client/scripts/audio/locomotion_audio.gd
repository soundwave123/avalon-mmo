class_name LocomotionAudio
extends RefCounted

# T-737: the playback half of locomotion audio — turns a FootstepCadence event into sound.
#
# Two paths, deliberately:
#   * YOUR OWN feet go through the AudioManager 2D one-shot pool. Own footsteps are not a thing
#     you localise in space; they are always centred and always at full level. Reusing the pool
#     also means the T-078 user SFX slider applies for free.
#   * EVERYONE ELSE (remote players, mobs) gets an AudioStreamPlayer3D parented to their body and
#     REUSED across footfalls — one emitter per entity, never one per step. That satisfies the
#     ticket's "remote players' footsteps too (positional, quieter)" and, because pilot.gd's
#     _audio_graph() enumerates AudioStreamPlayer3D nodes by scene path, every one of them shows
#     up in the T-415 audio-graph dump automatically. The dump is the verification instrument.
#
# Attenuation mirrors AmbientFxLayer.build_emitters(), the block T-415 already verified in-world.

const EMITTER_NAME := "FootstepEmitter"

# Other people's feet sit under your own. Distance attenuation is on top of this — the trim is
# what stops a crowd in the market square from drowning out your own gait at zero range.
const REMOTE_TRIM_DB := -6.0

# ~full level within this radius, then inverse-distance rolloff; culled past MAX_DISTANCE. A
# footfall is a small, near sound: you should hear someone jog past, not someone across the field.
const UNIT_SIZE := 4.0
const MAX_DISTANCE := 26.0

static var _cache: Dictionary = {}


# Every clip name locomotion can ask for — the surface footfalls plus the mount gait set. Used by
# the T-415 loop-enum gate to assert none of them ever loops.
static func clip_names() -> Array:
	var names: Array = []
	for surface in FootstepCadence.SURFACES:
		for i in range(FootstepCadence.VARIATIONS):
			names.append(FootstepCadence.clip_for(FootstepCadence.GAIT_WALK, surface, i))
	for i in range(FootstepCadence.VARIATIONS):
		names.append(FootstepCadence.clip_for(FootstepCadence.GAIT_MOUNT_GALLOP, "", i))
	return names


# Load a locomotion clip by its AudioManager.SFX key, cached. Unknown names return null so a
# missing asset drops that footfall instead of crashing a run (AudioManager.play_sfx's contract).
static func stream_for(clip_name: String) -> AudioStream:
	if _cache.has(clip_name):
		return _cache[clip_name]
	if not AudioManager.SFX.has(clip_name):
		return null
	var s := load(AudioManager.SFX[clip_name]) as AudioStream
	_cache[clip_name] = s
	return s


# The one positional emitter for a body, created on first use and reused thereafter.
static func ensure_emitter(body: Node3D) -> AudioStreamPlayer3D:
	if body == null or not is_instance_valid(body):
		return null
	var existing := body.get_node_or_null(EMITTER_NAME)
	if existing is AudioStreamPlayer3D:
		return existing
	var e := AudioStreamPlayer3D.new()
	e.name = EMITTER_NAME
	e.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	e.unit_size = UNIT_SIZE
	e.max_distance = MAX_DISTANCE
	e.max_db = 0.0  # never boosted when the listener is right on top of it
	body.add_child(e)
	return e


# Fire one positional footfall on `body`. Returns the emitter (for tests) or null if the clip is
# unknown / the body is gone.
static func play_step_3d(
	body: Node3D, clip_name: String, volume_db: float, pitch: float
) -> AudioStreamPlayer3D:
	var s := stream_for(clip_name)
	if s == null:
		return null
	var e := ensure_emitter(body)
	if e == null:
		return null
	e.stream = s
	e.volume_db = volume_db
	e.pitch_scale = pitch
	e.play()
	return e


# Fire a whole tick's worth of cadence events for a remote entity.
static func play_remote_steps(body: Node3D, events: Array) -> void:
	for ev: Dictionary in events:
		play_step_3d(
			body, str(ev["clip"]), float(ev["gain_db"]) + REMOTE_TRIM_DB, float(ev["pitch"])
		)


# One remote entity's footfalls for this frame: lazily owns a FootstepCadence in the entity dict
# (so every player and mob keeps its own gait phase and its own shuffle bag — two mobs walking
# side by side must not land in lockstep) and plays whatever lands on that entity's body.
#
# Lives here rather than in remote_entities_layer.gd because that file sits at 995 of its 1000
# line cap; keeping the body here costs the layer two lines instead of fifteen.
#
# `indoors` is not resolved for remote entities — the interior gate tracks only the local player,
# so a remote walking around inside a building is given its outdoor surface. Noted in T-737 as a
# follow-up; it is inaudible in practice because interiors are small and the trim is -6 dB.
static func tick_entity(e: Dictionary, body: Node3D, delta: float, speed: float) -> void:
	if body == null or not is_instance_valid(body):
		return
	var cadence = e.get("footsteps")
	if cadence == null:
		cadence = FootstepCadence.new()
		e["footsteps"] = cadence
		# Skip the frame an entity first appears on. The caller derives speed from this frame's
		# displacement, and on frame one that is (spawn position - the node's default position) —
		# a snap, not a step. FootstepCadence.MAX_SPEED_MPS catches the big ones, but a mob that
		# happens to spawn only a few metres from the origin lands UNDER the ceiling and would
		# otherwise fire a phantom footfall. Verified with the T-415 audio-graph dump: emitters on
		# idle mobs went 45 -> 33 with the ceiling alone, and 33 -> 0 once this skip was added.
		return
	var pos := body.global_position
	var surface := TerrainSurface.surface_at(pos.x, pos.z)
	play_remote_steps(body, cadence.tick(delta, speed, bool(e.get("mounted", false)), surface))


# Fire a whole tick's worth of cadence events for the local player through the 2D pool.
static func play_own_steps(audio: Node, events: Array) -> void:
	if audio == null or not is_instance_valid(audio):
		return
	for ev: Dictionary in events:
		audio.play_sfx(str(ev["clip"]), float(ev["gain_db"]), float(ev["pitch"]))
