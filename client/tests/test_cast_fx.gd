extends GutTest

# T-732: the ability presentation TIMELINE, headless — the event-order half of the DoD (the frame
# capture is the visual pass). The owner's 2026-08-08 bug: a cast-time mage spell fired its cue,
# shimmer AND bolt on the key press, so the whole show played at cast START and the damage landing
# seconds later had nothing to show. These pin the corrected order against a spy VFX layer:
#
#   press (cast-time) -> NOTHING          cast_started -> cue + channel, still nothing landing
#   cast_cancelled    -> channel off      ability_result -> channel off, then bolt + impact
#   press (instant)   -> unchanged: cue + shimmer + bolt now, impact on the result
#
# Plus T-721's folded-in follow-up: a spell-queue RETRY is cued when the cast actually starts,
# because the cue keys off the server's accept rather than the press. `audio` is deliberately null
# on the stub (AbilitySfx is typed to a real AudioManager, covered by test_ability_sfx.gd) — the cue
# BEAT is asserted through CastFx.beats().

const CastFxScript = preload("res://scripts/combat/cast_fx.gd")

const FROSTBOLT := 204  # cast-time in the kit stub below
const FIRE_BLAST := 202  # instant
const TARGET_ID := 1051
const MY_PEER := 7


class VfxSpy:
	extends Node3D
	var calls: Array = []
	var channelling := false

	func spawn_cast(_pos: Vector3, ability_id := -1) -> void:
		calls.append("cast:%d" % ability_id)

	func spawn_projectile(_from: Vector3, _to: Vector3, ability_id := -1) -> void:
		calls.append("projectile:%d" % ability_id)

	func spawn_impact_on(_pos: Vector3, _target: Node3D, ability_id := -1) -> void:
		calls.append("impact:%d" % ability_id)

	func spawn_heal(_pos: Vector3) -> void:
		calls.append("heal")

	func spawn_gunshot(_shooter: Node3D, _pos: Vector3) -> void:
		calls.append("gunshot")

	func start_channel(_pos: Vector3, ability_id := -1) -> void:
		channelling = true
		calls.append("channel_on:%d" % ability_id)

	func stop_channel() -> void:
		channelling = false
		calls.append("channel_off")

	func is_channeling() -> bool:
		return channelling


class EntitiesStub:
	extends Node
	var node: Node3D = null

	func has_target(id: int) -> bool:
		return node != null and id > 0

	func target_node(id: int) -> Node3D:
		return node if id > 0 else null


class MainStub:
	extends Node
	var _my_peer_id: int = 7
	var _target_id: int = 1051
	var _kit: Array = [{"id": 204, "cast_ticks": 30}, {"id": 202, "cast_ticks": 0}]
	var audio = null  # see the header: the cue beat is asserted through CastFx.beats()
	var vfx: VfxSpy = null
	var local_player: Node3D = null
	var remote_entities: EntitiesStub = null


var _fx: CastFx = null
var _main: MainStub = null
var _vfx: VfxSpy = null


func before_each() -> void:
	_main = MainStub.new()
	add_child_autofree(_main)
	_vfx = VfxSpy.new()
	_main.add_child(_vfx)
	var body := Node3D.new()
	_main.add_child(body)
	var victim := Node3D.new()
	_main.add_child(victim)
	victim.global_position = Vector3(5.0, 0.0, 0.0)
	var ents := EntitiesStub.new()
	ents.node = victim
	_main.add_child(ents)
	_main.vfx = _vfx
	_main.local_player = body
	_main.remote_entities = ents
	_fx = CastFxScript.new()


func _result(ability_id: int, extra: Dictionary = {}) -> Dictionary:
	var d := {
		"type": "ability_result",
		"ability_id": ability_id,
		"caster_id": MY_PEER,
		"target_id": TARGET_ID,
		"damage": 42,
		"outcome": "hit",
	}
	d.merge(extra, true)
	return d


# ---- the reported bug: nothing lands before the server says it did ------------------------------


func test_cast_time_press_shows_and_says_nothing() -> void:
	_fx.on_press(_main, FROSTBOLT, TARGET_ID)
	assert_eq(_vfx.calls, [], "a cast-time press fires NO vfx (T-732: it used to fire all of it)")
	assert_eq(_fx.beats(), [], "and no audible beat either — the server has not accepted it yet")
	assert_false(_fx.is_channelling(), "the press alone does not start a channel")


func test_no_impact_visual_before_the_ability_result() -> void:
	_fx.on_press(_main, FROSTBOLT, TARGET_ID)
	_fx.on_combat_event(_main, {"type": "cast_started", "ability_id": FROSTBOLT, "cast_ticks": 30})
	for call: String in _vfx.calls:
		assert_false(call.begins_with("impact"), "no impact burst during the cast (%s)" % call)
		assert_false(call.begins_with("projectile"), "no bolt during the cast (%s)" % call)
	assert_true(_vfx.is_channeling(), "the wind-up IS showing — the channel is live")
	assert_eq(
		_fx.beats(),
		["cue:204", "channel_on:204"],
		"cast_started is what cues the spell and lights the hands"
	)


func test_channel_runs_for_the_cast_then_the_delivery_lands_on_the_result() -> void:
	_fx.on_combat_event(_main, {"type": "cast_started", "ability_id": FROSTBOLT, "cast_ticks": 30})
	_fx.on_combat_event(_main, _result(FROSTBOLT))
	assert_eq(
		_vfx.calls,
		["channel_on:204", "channel_off", "projectile:204", "impact:204"],
		"wind-up during the cast; the bolt and the impact only on the server's completion"
	)
	assert_false(_fx.is_channelling(), "the completed cast released the channel")
	assert_eq(
		_fx.beats(), ["cue:204", "channel_on:204", "channel_off:204", "bolt:204", "impact:204"]
	)


func test_impact_rides_the_same_event_as_the_damage_number() -> void:
	# main.gd spawns the floating damage number from ability_result; the impact burst is dispatched
	# from that same call, so the number and the hit can never drift apart again.
	_fx.on_combat_event(_main, {"type": "cast_started", "ability_id": FROSTBOLT, "cast_ticks": 30})
	assert_false(_vfx.calls.has("impact:204"), "no impact yet")
	_fx.on_combat_event(_main, _result(FROSTBOLT))
	assert_true(_vfx.calls.has("impact:204"), "the impact is dispatched by the result handler")


func test_a_cancelled_cast_lands_nothing() -> void:
	_fx.on_combat_event(_main, {"type": "cast_started", "ability_id": FROSTBOLT, "cast_ticks": 30})
	_fx.on_combat_event(_main, {"type": "cast_cancelled", "reason": "moved"})
	assert_eq(
		_vfx.calls,
		["channel_on:204", "channel_off"],
		"an interrupted cast shows no bolt, no impact"
	)
	assert_false(_fx.is_channelling(), "the interrupt released the channel")


func test_a_mismatched_result_still_releases_the_channel() -> void:
	# Defensive: our own result for a DIFFERENT ability must not strand the glow on the caster.
	_fx.on_combat_event(_main, {"type": "cast_started", "ability_id": FROSTBOLT, "cast_ticks": 30})
	_fx.on_combat_event(_main, _result(FIRE_BLAST))
	assert_false(_fx.is_channelling(), "a stray result of ours clears the channel")
	assert_false(_vfx.calls.has("projectile:202"), "but it does not fire the casting spell's bolt")


# ---- instants are untouched --------------------------------------------------------------------


func test_instant_ability_keeps_its_press_beat() -> void:
	_fx.on_press(_main, FIRE_BLAST, TARGET_ID)
	assert_eq(
		_vfx.calls, ["cast:202", "projectile:202"], "an instant still shows shimmer + bolt on press"
	)
	assert_eq(_fx.beats(), ["cue:202", "shimmer:202", "bolt:202"], "cued by the press, as before")
	_fx.on_combat_event(_main, _result(FIRE_BLAST))
	assert_eq(
		_vfx.calls,
		["cast:202", "projectile:202", "impact:202"],
		"its result adds the impact only — no second bolt, no channel"
	)


func test_another_casters_result_still_lands_its_impact() -> void:
	_fx.on_combat_event(_main, _result(FIRE_BLAST, {"caster_id": 99}))
	assert_eq(
		_vfx.calls, ["impact:202"], "a mob hitting you shows its impact, no caster-side beats"
	)


func test_heal_and_ranged_results_keep_their_carved_dispatch() -> void:
	_fx.on_combat_event(_main, _result(301, {"outcome": "heal", "heal": 20, "damage": 0}))
	_fx.on_combat_event(_main, _result(1, {"ranged": true}))
	assert_eq(
		_vfx.calls, ["heal", "gunshot"], "T-343 heal + T-350 gunshot dispatch survived the carve"
	)


# ---- T-721 follow-up: the retried queued cast --------------------------------------------------


func test_a_retried_queued_cast_is_cued_when_it_actually_starts() -> void:
	# The T-721 spell queue: the press is refused on_gcd and re-sent ~0.6 s later. Pre-T-732 the cue
	# played at the (refused) press and never again; now it plays when the server starts the cast.
	_fx.on_press(_main, FROSTBOLT, TARGET_ID)
	_fx.on_combat_event(
		_main,
		{
			"type": "ability_rejected",
			"ability_id": FROSTBOLT,
			"reason": "on_gcd",
			"detail": {"gcd_ready_in_ticks": 12}
		}
	)
	assert_eq(_fx.beats(), [], "a refused press makes no phantom cue")
	# ...AbilityCastQueue re-sends, and the server accepts this time:
	_fx.on_combat_event(_main, {"type": "cast_started", "ability_id": FROSTBOLT, "cast_ticks": 30})
	assert_eq(_fx.beats().count("cue:204"), 1, "the retried cast IS cued — exactly once")
	assert_true(_vfx.is_channeling(), "and it shows its wind-up")


# ---- the pure kit lookup ------------------------------------------------------------------------


func test_cast_ticks_for_reads_the_kit_row() -> void:
	assert_eq(CastFxScript.cast_ticks_for(_main._kit, FROSTBOLT), 30, "cast-time spell")
	assert_eq(CastFxScript.cast_ticks_for(_main._kit, FIRE_BLAST), 0, "instant spell")


func test_cast_ticks_for_treats_an_unknown_ability_as_instant() -> void:
	assert_eq(
		CastFxScript.cast_ticks_for(_main._kit, 999), 0, "no kit row = the pre-T-732 behaviour"
	)
	assert_eq(CastFxScript.cast_ticks_for(null, FROSTBOLT), 0, "no kit at all (pre-class_kit)")
