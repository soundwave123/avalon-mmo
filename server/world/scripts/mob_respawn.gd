extends RefCounted

# T-514b carve: mob DEAD→IDLE respawn state reset + broadcast payload, lifted out of world/main.gd
# to keep that file under the gdlint max-file-lines cap. Pure/static — mutates the passed mob entry
# back to its spawn config and RETURNS the "mob_respawn" broadcast payload for the caller to emit.
# Behavior is byte-identical to the original main.gd::_handle_mob_respawn (T-026); no field the
# second-tick persistence test relies on is dropped (resources copy + position/state reset intact).

const _MAI = preload("res://scripts/combat/mob_ai.gd")


# Reset mobs[mob_id] to its spawn config and return the broadcast payload the caller broadcasts.
static func respawn(mobs: Dictionary, mob_id: int) -> Dictionary:
	var mob = mobs[mob_id]
	mob.resources = mob.resources.apply_damage(0)  # copy, then restore to original spawn config
	mob.resources.hp = mob.resources.max_hp
	mob.resources.mana = mob.resources.max_mana
	mob.resources.stamina = mob.resources.max_stamina
	mob.position = mob.spawn_position
	mob.ai_state = _MAI.MobAIState.IDLE
	mob.current_target_id = -1
	mobs[mob_id] = mob
	return {
		"type": "mob_respawn",
		"mob_id": mob_id,
		"mob_name": mob.name,
		"target_id": mob_id,
		"target_name": mob.name,
		"caster_name": "",
		"caster_id": "",
		"hp": mob.resources.max_hp,
		"max_hp": mob.resources.max_hp,
	}
