extends RefCounted
# T-426 (carve): builds the server-authoritative EntitySnapshot the ability executor consumes, from
# the world's per-peer combat dicts. Extracted from main.gd (_snap_caster/_snap_target) to keep that
# file under the 1000-line cap. Holds references to main's state dicts, bound once at boot — the
# dicts are mutated in place, never reassigned, so the references stay live (matches the
# _move_limiter / _resource_ticker service pattern). Snapshots come from server state, never client.

const _ES = preload("res://scripts/combat/entity_snapshot.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

var _states: Dictionary
var _resources: Dictionary
var _stats: Dictionary
var _class: Dictionary
var _mods: Dictionary
var _level: Dictionary
var _unlocked: Dictionary


func bind(
	states: Dictionary,
	resources: Dictionary,
	stats: Dictionary,
	char_class: Dictionary,
	mods: Dictionary,
	level: Dictionary,
	unlocked: Dictionary
) -> void:
	_states = states
	_resources = resources
	_stats = stats
	_class = char_class
	_mods = mods
	_level = level
	_unlocked = unlocked


func caster(peer_id: int):
	var s := _ES.new()
	s.peer_id = peer_id
	s.position = PlayerSessions.get_player(peer_id).get("pos", Vector3.ZERO)
	s.combat_state = _states[peer_id]
	s.resources = _resources[peer_id]
	s.stats = _stats[peer_id]
	s.char_class = _class.get(peer_id, "")
	s.is_mob = false
	s.ability_mods = _mods.get(peer_id, {})  # T-064
	s.level = _level.get(peer_id, 1)  # T-365: rank scaling
	s.unlocked = _unlocked.get(peer_id, [])  # T-365: trained-ability ownership gate
	return s


func target(target_id: int, target_player: Dictionary, target_mob, target_cs):
	var s := _ES.new()
	var is_mob: bool = target_mob != null
	s.peer_id = target_id
	s.position = target_mob.position if is_mob else target_player.get("pos", Vector3.ZERO)
	s.combat_state = target_cs
	s.resources = target_mob.resources if is_mob else _resources[target_id]
	s.stats = target_mob.stats if is_mob else _stats[target_id]
	s.char_class = "" if is_mob else _class.get(target_id, "")
	s.is_mob = is_mob
	s.control_immune = bool(target_mob.control_immune) if is_mob else false
	s.interrupt_immune = bool(target_mob.interrupt_immune) if is_mob else false
	return s
