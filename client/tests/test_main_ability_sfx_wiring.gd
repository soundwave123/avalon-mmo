extends GutTest

# T-343 phase 3: prove the restyled kit's SOUND beats fire through the REAL main.gd paths (the
# T-578 lesson: mapping tests alone can pass while main.gd's wiring discards them). These drive
# main._cast_kit_slot / main._on_combat on a real MainScene instance with a real AudioManager and
# assert the pool player that just fired holds the school-mapped stream at the mapped pitch.

const MainScene = preload("res://scripts/main.gd")
const AudioManagerScene = preload("res://scripts/audio/audio_manager.gd")
const AbilitySfxLib = preload("res://scripts/audio/ability_sfx.gd")
const CombatFeedbackScene = preload("res://scripts/combat/combat_feedback.gd")
const RemoteEntitiesScene = preload("res://scripts/world/remote_entities_layer.gd")
const PlayerHudScene = preload("res://scripts/ui/player_hud.gd")


class NetSpy:
	var used: Array = []

	func request_use_ability(ability_id: int, target_id: int) -> void:
		used.append([ability_id, target_id])


var _main = null
var _am = null


func before_each() -> void:
	_main = MainScene.new()
	_main._smoke = false
	_am = AudioManagerScene.new()
	add_child_autofree(_am)
	_main.audio = _am


func after_each() -> void:
	if _main != null:
		_main.free()
		_main = null


# The pool player play_sfx just wrote (round-robin: one behind the cursor).
func _fired() -> AudioStreamPlayer:
	var n: int = _am._sfx_players.size()
	return _am._sfx_players[(_am._sfx_idx - 1 + n) % n]


func _cast(ability_id: int, ability_name: String) -> void:
	var hud = PlayerHudScene.new()
	add_child_autofree(hud)
	var kit: Array = [{"id": ability_id, "name": ability_name}]
	hud.set_kit(kit)
	_main.player_hud = hud
	_main._kit = kit
	_main._target_id = 7
	_main._net = NetSpy.new()
	_main._cast_kit_slot(0)


func _result(data: Dictionary) -> void:
	var feedback = CombatFeedbackScene.new()
	add_child_autofree(feedback)
	var remotes = RemoteEntitiesScene.new()
	add_child_autofree(remotes)
	_main.combat_feedback = feedback
	_main.remote_entities = remotes
	_main._my_peer_id = 99
	data["type"] = "ability_result"
	_main._on_combat(data)


func test_fireball_cast_fires_the_fire_charge_cue() -> void:
	_cast(201, "Fireball")
	assert_eq(
		_fired().stream.resource_path,
		str(AudioManagerScene.SFX["fire_cast"]),
		"casting fireball through the real slot path plays the fire charge"
	)
	assert_almost_eq(_fired().pitch_scale, 1.0, 0.001, "fireball charge at base pitch")


func test_heroic_strike_cast_fires_the_swing_whoosh_pitch_variant() -> void:
	_cast(101, "Heroic Strike")
	assert_eq(
		_fired().stream.resource_path,
		str(AudioManagerScene.SFX["melee_swing"]),
		"a warrior press swings air, not the arcane shimmer"
	)
	assert_almost_eq(_fired().pitch_scale, 0.95, 0.001, "heroic strike's mapped pitch variant")


func test_fire_impact_lands_the_fire_hit_not_the_generic_thud() -> void:
	_result({"ability_id": 201, "damage": 12, "target_id": 3, "caster_id": 99, "outcome": "hit"})
	assert_eq(
		_fired().stream.resource_path,
		str(AudioManagerScene.SFX["fire_impact"]),
		"a landed fireball whoomps through the real ability_result path"
	)


func test_smite_impact_lands_the_holy_strike() -> void:
	_result({"ability_id": 303, "damage": 9, "target_id": 3, "caster_id": 99, "outcome": "hit"})
	assert_eq(_fired().stream.resource_path, str(AudioManagerScene.SFX["holy_impact"]))


func test_landed_heal_rings_the_heal_chime() -> void:
	_result({"ability_id": 305, "heal": 30, "target_id": 3, "caster_id": 99, "outcome": "heal"})
	assert_eq(
		_fired().stream.resource_path,
		str(AudioManagerScene.SFX["heal_chime"]),
		"a landed greater heal rings the warm chime (a beat that used to be silent)"
	)
	assert_almost_eq(_fired().pitch_scale, 1.0, 0.001, "greater heal at base pitch")


func test_frost_money_hit_is_unchanged_by_the_phase3_routing() -> void:
	_result({"ability_id": 204, "damage": 26, "target_id": 3, "caster_id": 99, "outcome": "hit"})
	assert_eq(
		_fired().stream.resource_path,
		str(AudioManagerScene.SFX["frost_impact"]),
		"the phase-2 frost reference still lands its shatter through the new map"
	)
