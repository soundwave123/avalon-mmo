class_name CastFx
extends RefCounted
# T-721 carve, reworked by T-732: the client-side ABILITY PRESENTATION TIMELINE. Every beat the
# player sees or hears for an ability — the cast cue, the caster shimmer, the bolt, the impact — is
# scheduled here, and since T-732 off SERVER-CONFIRMED events rather than off the key press. Reads
# Main's fields lazily (the AutoAttackMode/AbilityCastQueue idiom) so main.gd stays under its
# 1000-line cap. Pure presentation — the server still validates and gates every actual use.
#
# T-732 (owner playtest 2026-08-08): a cast-time spell fired its WHOLE presentation the instant the
# press left the client — cue, shimmer AND the bolt — so the money beat played at cast START and the
# damage landing 2-3 s later had nothing to show. The corrected timeline:
#
#   press           INSTANT ability -> the launch beat exactly as before (cue + shimmer + bolt).
#                   CAST-TIME (the kit's cast_ticks > 0) -> NOTHING; the server has not even
#                   accepted it yet, and the beat it used to play belongs seconds later.
#   cast_started    the accept: the school-voiced cue (T-343 p3) + the CHANNEL — the cast style's
#                   hand-glow re-pulsed for the whole wind-up (VfxManager.start_channel), under the
#                   T-265 cast bar and alongside the T-123 cast pose.
#   cast_cancelled  channel off. Interrupted / target lost: nothing landed, so nothing is shown.
#   ability_result  channel off, then the DELIVERY (bolt + impact), off the very event main.gd
#                   spawns the floating damage number from, so the number and the hit read as one.
#
# T-721's cosmetic follow-up rides along: because the cue keys off the server's ACCEPT instead of
# the press, a spell-queue RETRY (a press refused on_gcd, re-sent by AbilityCastQueue) is cued when
# the cast actually starts, and a refused press makes no phantom noise. Instants stay press-driven
# on purpose — the T-057 auto-attack Strike never came through here, so a result-driven cue would
# have added a swing whoosh to every auto-swing.
#
# `beats()` is the headless event-order surface the T-732 DoD is tested against (and, like
# AbilityCastQueue.summary(), a diagnostic the pilot can read back).

const FROSTBOLT_ABILITY_ID := 204  # mirrors main.gd's const (same wire id)
const BEATS_CAP := 40  # recent-beat ring; the trace is for tests/diagnostics, not a log

# The cast-time ability the server currently has us channelling (-1 = not casting). Set by
# cast_started, cleared by cast_cancelled or by any ability_result of ours.
var _casting_ability: int = -1
var _beats: Array = []

# ---- press (main._cast_kit_slot) ------------------------------------------------------------


# A manual action-bar press just left the client for the server.
func on_press(main: Node, ability_id: int, target_id: int) -> void:
	if cast_ticks_for(main.get("_kit"), ability_id) > 0:
		return  # T-732: a cast-time spell shows nothing until the server says the cast STARTED
	_launch(main, ability_id, target_id, true)


# PURE: the kit's cast time in ticks for an ability id (0 = instant, or an id we have no kit row
# for — an unknown ability is treated as instant, which is the pre-T-732 behaviour).
static func cast_ticks_for(kit: Variant, ability_id: int) -> int:
	if not (kit is Array):
		return 0
	for ab: Variant in kit:
		if ab is Dictionary and int((ab as Dictionary).get("id", -1)) == ability_id:
			return int((ab as Dictionary).get("cast_ticks", 0))
	return 0


# ---- server verdicts (main._on_combat) ------------------------------------------------------


func on_combat_event(main: Node, d: Dictionary) -> void:
	var abil := int(d.get("ability_id", -1))
	match str(d.get("type", "")):
		"cast_started":  # only ever sent to the caster (= us)
			_begin_channel(main, abil)
		"cast_cancelled":
			_end_channel(main)
		"ability_result":
			_on_result(main, d, abil)


func _on_result(main: Node, d: Dictionary, ability_id: int) -> void:
	# Our own cast-time spell completing is the moment the delivery beat belongs to. Any result of
	# ours ends the channel (so a mismatched id can never strand the glow), but only the ability we
	# were actually casting fires the bolt.
	if int(d.get("caster_id", -1)) == int(main.get("_my_peer_id")) and _casting_ability >= 0:
		var was := _casting_ability
		_end_channel(main)
		if was == ability_id:
			_launch(main, ability_id, int(d.get("target_id", -1)), false)
	_impact(main, d, ability_id)


# ---- beats ------------------------------------------------------------------------------------


# The launch beat: the cue (press-time only — a completing cast was already cued at its start), the
# caster shimmer, and the bolt to the target. T-110 + T-343 p3.
func _launch(main: Node, ability_id: int, target_id: int, cue: bool) -> void:
	var audio: AudioManager = main.get("audio")
	if cue:
		_note("cue", ability_id)
		if audio != null:
			AbilitySfx.play_cast(audio, ability_id)
	var vfx = main.get("vfx")
	var caster: Node3D = main.get("local_player")
	if vfx == null or caster == null:
		return
	if cue:  # the shimmer belongs to the wind-up; a cast-time spell already glowed for its channel
		vfx.spawn_cast(caster.global_position, ability_id)
		_note("shimmer", ability_id)
	var entities = main.get("remote_entities")
	if entities == null or not entities.has_target(target_id):
		return
	vfx.spawn_projectile(
		caster.global_position, entities.target_node(target_id).global_position, ability_id
	)
	_note("bolt", ability_id)
	if ability_id == FROSTBOLT_ABILITY_ID and audio != null:  # T-343: icy whoosh at launch
		audio.play_sfx("frost_flight", -8.0)


# T-732: the wind-up. The cue the press used to make, plus the sustained channel glow, both at the
# server-confirmed start of the cast.
func _begin_channel(main: Node, ability_id: int) -> void:
	_casting_ability = ability_id
	_note("cue", ability_id)
	var audio: AudioManager = main.get("audio")
	if audio != null:
		AbilitySfx.play_cast(audio, ability_id)
	var vfx = main.get("vfx")
	var caster: Node3D = main.get("local_player")
	if vfx != null and caster != null:
		vfx.start_channel(caster.global_position, ability_id)
		_note("channel_on", ability_id)


func _end_channel(main: Node) -> void:
	if _casting_ability < 0:
		return
	var ended := _casting_ability
	_casting_ability = -1
	var vfx = main.get("vfx")
	if vfx != null:
		vfx.stop_channel()
	_note("channel_off", ended)


# T-110/T-343/T-350, carved out of main._on_combat by T-732 so the whole ability-VFX timeline lives
# in one file: the server-confirmed LANDING. Runs for every caster (a mob hitting you lands its
# impact too), off the same ability_result main.gd spawns the floating damage number from.
func _impact(main: Node, d: Dictionary, ability_id: int) -> void:
	var vfx = main.get("vfx")
	var entities = main.get("remote_entities")
	if vfx == null or entities == null:
		return
	var tnode: Node3D = entities.target_node(int(d.get("target_id", -1)))
	if tnode == null:
		return
	var tpos: Vector3 = tnode.global_position
	if str(d.get("outcome", "")) == "heal" or int(d.get("heal", 0)) > 0:
		vfx.spawn_heal(tpos)
		_note("heal", ability_id)
	elif int(d.get("damage", 0)) > 0:
		if bool(d.get("ranged", false)):  # T-350: muzzle flash + tracer + impact
			vfx.spawn_gunshot(entities.target_node(int(d.get("caster_id", -1))), tpos)
			_note("gunshot", ability_id)
		else:  # T-343: the frost bolt flash-freezes its victim (by ability id); else generic burst
			vfx.spawn_impact_on(tpos, tnode, ability_id)
			_note("impact", ability_id)


# ---- trace ------------------------------------------------------------------------------------


func is_channelling() -> bool:
	return _casting_ability >= 0


# The ordered beat trace ("cue:204", "channel_on:204", "channel_off:204", "bolt:204", ...). The cue
# is recorded whether or not an AudioManager is attached (it IS the beat); every visual beat is
# recorded only when it actually reached the VFX layer.
func beats() -> Array:
	return _beats.duplicate()


func clear_beats() -> void:
	_beats.clear()


func _note(beat: String, ability_id: int) -> void:
	_beats.append("%s:%d" % [beat, ability_id])
	if _beats.size() > BEATS_CAP:
		_beats.pop_front()
