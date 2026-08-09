extends GutTest

# T-729: auto-attack is a STICKY MODE. Owner playtest 2026-08-08: it dropped off between fights,
# so every mob cost a re-toggle. These tests pin the whole lifecycle — the pure decision table
# first, then the real main.gd + a real RemoteEntitiesLayer driven through two consecutive fights.
# The other half of the fix is silence (T-721's corpse-hammering follow-up), so the assertions
# count SENDS on the wire via NetSpy, not rejects — the only honest form of "zero swings".

const MainScene = preload("res://scripts/main.gd")
const Mode = preload("res://scripts/combat/autoattack_mode.gd")
const RemoteEntitiesScene = preload("res://scripts/world/remote_entities_layer.gd")
const PlayerHudScene = preload("res://scripts/ui/player_hud.gd")
const IndicatorState = preload("res://scripts/ui/autoattack_indicator_state.gd")
const CombatFeedbackScene = preload("res://scripts/combat/combat_feedback.gd")
const DeathPresentation = preload("res://scripts/ui/death_presentation.gd")

const LIVE_MOB := {"hp": 40, "max_hp": 40, "is_player": false, "hostile": true}
const DEAD_MOB := {"hp": 0, "max_hp": 40, "is_player": false, "hostile": true}

var _main = null
var _spy: NetSpy = null
var _remotes = null
var _hud = null
var _timer: Timer = null


class NetSpy:
	extends RefCounted
	var ability_calls: Array = []

	func request_use_ability(ability_id: int, target_id: int) -> void:
		ability_calls.append([ability_id, target_id])


func test_mode_off_stops_the_swing_timer() -> void:
	assert_eq(Mode.decide(false, 1001, LIVE_MOB, false), Mode.Tick.STOP)


func test_live_hostile_selection_swings() -> void:
	assert_eq(Mode.decide(true, 1001, LIVE_MOB, false), Mode.Tick.SWING)


func test_dead_target_idles_instead_of_hammering_the_corpse() -> void:
	# T-721 follow-up: the old timer kept casting Strike at 0 HP until the mob respawned.
	assert_eq(Mode.decide(true, 1001, DEAD_MOB, false), Mode.Tick.IDLE)


func test_no_target_idles_and_never_acquires_one() -> void:
	# Sticky mode is not an aim-bot: with nothing selected it stays armed and stays silent.
	assert_eq(Mode.decide(true, -1, {}, false), Mode.Tick.IDLE)


func test_training_dummies_stay_swingable_disposition_is_not_permission() -> void:
	# broadcast_builder sends hostile:false for dummy/retaliate_only units — which is EXACTLY what
	# the Training Dummy and the Straw Sparring Effigy are, and they exist to be auto-attacked
	# (T-721 built its rage on one). Gating the swing on disposition would silently break them.
	var dummy := {"hp": 200, "is_player": false, "hostile": false}
	assert_eq(Mode.decide(true, 1051, dummy, false), Mode.Tick.SWING)


func test_player_target_stays_swingable_server_owns_pvp_legality() -> void:
	var other := {"hp": 100, "is_player": true}
	assert_eq(Mode.decide(true, 7, other, false), Mode.Tick.SWING)


func test_death_locked_client_sends_nothing_but_keeps_the_mode() -> void:
	assert_eq(Mode.decide(true, 1001, LIVE_MOB, true), Mode.Tick.IDLE)


func test_vanished_selection_drops_the_target_not_the_mode() -> void:
	assert_eq(Mode.decide(true, 1001, {}, false), Mode.Tick.DROP_TARGET)


func test_is_swingable_reads_the_server_row() -> void:
	assert_true(Mode.is_swingable(LIVE_MOB))
	assert_false(Mode.is_swingable(DEAD_MOB))
	assert_false(Mode.is_swingable({}))
	assert_true(Mode.is_swingable({"is_player": false}), "no hp key yet → assume alive")


# Live lifecycle: Main is built WITHOUT entering the tree (its scene-dependent _ready never runs);
# only the seams the auto-attack lifecycle touches are wired, all of them real objects.
func before_each() -> void:
	_main = MainScene.new()
	_spy = NetSpy.new()
	_remotes = RemoteEntitiesScene.new()
	add_child_autofree(_remotes)
	_hud = PlayerHudScene.new()
	add_child_autofree(_hud)
	_timer = Timer.new()
	add_child_autofree(_timer)
	await get_tree().process_frame
	_main.remote_entities = _remotes
	_main.player_hud = _hud
	_main._attack_timer = _timer
	_main._net = _spy
	_main._my_peer_id = 99
	_broadcast(true, true)


func after_each() -> void:
	if _main != null:
		# Main instantiates these two at declaration; without _ready they never became children,
		# so free them here instead of leaking an orphan per test.
		_main._cast_queue.free()
		_main._onboarding.free()
		_main.free()
		_main = null


# Both mobs in this client's snapshot; either can be sent as a corpse (hp 0), and dropping a mob
# from the rows entirely is how the server tells us it left our interest area.
func _broadcast(alive_1001: bool, alive_1002: bool, include_1001: bool = true) -> void:
	var mobs: Array = []
	if include_1001:
		mobs.append(_mob_row(1001, 10.0, alive_1001))
	mobs.append(_mob_row(1002, 14.0, alive_1002))
	_remotes.ingest({"players": [], "mobs": mobs}, 99, 1000)


func _mob_row(mob_id: int, x: float, alive: bool) -> Dictionary:
	var row := {"mob_id": mob_id, "x": x, "y": 10, "z": 0, "max_hp": 40, "hostile": true}
	row["hp"] = 40 if alive else 0
	return row


func _swings_at(target_id: int) -> int:
	var n := 0
	for call: Array in _spy.ability_calls:
		if int(call[0]) == 1 and int(call[1]) == target_id:
			n += 1
	return n


func test_two_fights_one_toggle() -> void:
	# The ticket's DoD in client-lifecycle form: kill fight 1's mob, select fight 2's mob, and
	# swings resume with NO second press of the toggle.
	_main._on_entity_clicked(1001)
	_main._toggle_autoattack()
	assert_true(_main._autoattack, "fight 1: mode armed")
	assert_eq(_swings_at(1001), 1, "arming swings immediately at the live hostile")
	_main._on_attack_tick()
	assert_eq(_swings_at(1001), 2, "and keeps swinging on the timer")

	_broadcast(false, true)  # mob 1001 dies; its corpse stays in the snapshot until respawn
	var sends_at_death: int = _spy.ability_calls.size()
	_main._on_attack_tick()
	_main._on_attack_tick()
	assert_eq(_spy.ability_calls.size(), sends_at_death, "ZERO swings at the corpse (T-721 noise)")
	assert_true(_main._autoattack, "the kill does NOT drop the mode")

	_main._on_entity_clicked(1002)  # fight 2 — no re-toggle
	assert_eq(_swings_at(1002), 1, "swings resume on the next hostile selection")
	_main._on_attack_tick()
	assert_eq(_swings_at(1002), 2, "fight 2 runs on the timer like fight 1")
	assert_true(_main._autoattack, "still armed after the switch")


func test_target_switch_mid_fight_keeps_the_mode_and_retargets() -> void:
	_main._on_entity_clicked(1001)
	_main._toggle_autoattack()
	_main._on_entity_clicked(1002)  # switch while mob 1001 is still alive
	assert_true(_main._autoattack, "switching targets does not drop the mode")
	assert_eq(_swings_at(1002), 1, "the swing follows the new selection immediately")
	_main._on_attack_tick()
	assert_eq(_swings_at(1001), 1, "no stray swings at the abandoned target")


func test_combat_drop_deselect_keeps_the_mode_armed_and_silent() -> void:
	_main._on_entity_clicked(1001)
	_main._toggle_autoattack()
	_spy.ability_calls.clear()
	_main._clear_target()  # Esc-deselect / left-click on empty ground
	assert_true(_main._autoattack, "a combat drop does not drop the mode")
	assert_eq(_main._target_id, -1, "but the selection is gone")
	_main._on_attack_tick()
	_main._on_attack_tick()
	assert_eq(_spy.ability_calls.size(), 0, "no target → no use_ability on the wire at all")
	_main._on_entity_clicked(1002)
	assert_eq(_swings_at(1002), 1, "and it resumes on the next selection")


func test_player_death_keeps_the_mode_but_sends_nothing() -> void:
	# The real server-shaped death path (T-506), not a hand-rolled _clear_target.
	var feedback = CombatFeedbackScene.new()
	add_child_autofree(feedback)
	var presentation = DeathPresentation.new()
	add_child_autofree(presentation)
	await get_tree().process_frame
	presentation.setup(feedback.get_combat_log())
	_main.combat_feedback = feedback
	_main.death_presentation = presentation
	_main._on_entity_clicked(1001)
	_main._toggle_autoattack()
	_spy.ability_calls.clear()
	_main._on_combat({"type": "player_death", "peer_id": 99, "player_id": 99})
	assert_true(_main._autoattack, "your own death does not cost you the mode")
	assert_true(presentation.is_input_disabled(), "precondition: the death input lock is on")
	_main._on_entity_clicked(1002)  # a stray click during the dead hold must not swing
	_main._on_attack_tick()
	assert_eq(_spy.ability_calls.size(), 0, "a dead player swings at nothing")


func test_arming_without_a_target_is_allowed_and_silent() -> void:
	# Pre-T-729 the toggle refused to arm with no target — the mode is now independent of it.
	_main._toggle_autoattack()
	assert_true(_main._autoattack, "the mode arms with nothing selected")
	_main._on_attack_tick()
	assert_eq(_spy.ability_calls.size(), 0, "armed but idle: no auto-acquire, no sends")
	_main._on_entity_clicked(1001)
	assert_eq(_swings_at(1001), 1, "selecting a hostile is what starts the swinging")


func test_toggling_off_stops_the_timer_and_the_swings() -> void:
	_main._on_entity_clicked(1001)
	_main._toggle_autoattack()
	assert_true(_timer.is_stopped() == false, "armed → the swing timer runs")
	_spy.ability_calls.clear()
	_main._toggle_autoattack()
	assert_false(_main._autoattack)
	assert_true(_timer.is_stopped(), "disarmed → the timer halts")
	_main._on_attack_tick()
	assert_eq(_spy.ability_calls.size(), 0, "an off mode never swings")


func test_vanished_target_clears_the_selection_and_stays_armed() -> void:
	_main._on_entity_clicked(1001)
	_main._toggle_autoattack()
	_broadcast(true, true, false)  # mob 1001 left this client's interest area entirely
	_spy.ability_calls.clear()
	_main._on_attack_tick()
	assert_eq(_main._target_id, -1, "a vanished selection is dropped")
	assert_true(_main._autoattack, "…but the mode survives it")
	assert_eq(_spy.ability_calls.size(), 0, "and nothing went out on the wire")


func test_indicator_is_honest_about_all_three_states() -> void:
	assert_eq(_hud.autoattack_indicator.text, IndicatorState.OFF_TEXT, "starts OFF")
	_main._toggle_autoattack()  # armed, nothing selected
	assert_eq(_hud.autoattack_indicator.text, IndicatorState.IDLE_TEXT, "ON but idle reads as idle")
	_main._on_entity_clicked(1001)
	assert_eq(_hud.autoattack_indicator.text, IndicatorState.ON_TEXT, "swinging reads as ON")
	_broadcast(false, true)  # the mob dies under us
	_main._on_attack_tick()
	assert_eq(_hud.autoattack_indicator.text, IndicatorState.IDLE_TEXT, "a corpse reads as idle")
	_main._toggle_autoattack()
	assert_eq(_hud.autoattack_indicator.text, IndicatorState.OFF_TEXT, "and OFF is still OFF")


func test_auto_swings_never_disturb_the_t721_press_queue() -> void:
	# T-721: AbilityCastQueue only ever retries the LAST MANUAL press; auto-swings go out as a
	# plain request_use_ability and an on_gcd refusal of Strike must leave that press pending.
	var queue := AbilityCastQueue.new()
	add_child_autofree(queue)
	queue.note_manual_send(0, 101, 1001)  # the player's Heroic Strike
	_main._on_entity_clicked(1001)
	_main._toggle_autoattack()
	queue.on_combat_event(
		{"type": "ability_rejected", "ability_id": 1, "reason": "on_gcd", "detail": {}}
	)
	assert_eq(
		Mode.STRIKE_ABILITY_ID, 1, "the auto-swing is ability 1, never the queued manual press"
	)
	var pending: Dictionary = queue.get("_pending")
	assert_eq(int(pending.get("ability_id", -1)), 101, "the manual press is still queued")
	assert_eq(
		int(pending.get("retries_left", -1)), AbilityCastQueue.RETRY_CAP, "and unspent — untouched"
	)
