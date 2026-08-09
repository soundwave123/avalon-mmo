class_name CastFx
extends RefCounted
# T-721 carve from main._cast_kit_slot (kept main.gd under the 1000-line cap): the presentation
# burst when a manual cast leaves the client — school-voiced cast cue (T-343 p3), caster shimmer +
# ranged bolt to the target (T-110), and frost's icy whoosh at projectile launch (T-343).
# Pure presentation — the server still validates/gates the actual ability use.

const FROSTBOLT_ABILITY_ID := 204  # mirrors main.gd's const (same wire id)


static func on_cast_sent(
	audio, vfx, local_player, remote_entities, target_id: int, ability_id: int
) -> void:
	if audio != null:  # T-343 p3: every ability's school-voiced cast cue (frost unchanged)
		AbilitySfx.play_cast(audio, ability_id)
	if vfx != null and local_player != null:  # T-110: caster shimmer + a ranged bolt to the target
		vfx.spawn_cast(local_player.global_position, ability_id)
		if remote_entities != null and remote_entities.has_target(target_id):
			vfx.spawn_projectile(
				local_player.global_position,
				remote_entities.target_node(target_id).global_position,
				ability_id
			)
			if ability_id == FROSTBOLT_ABILITY_ID and audio != null:  # icy whoosh at launch
				audio.play_sfx("frost_flight", -8.0)
