class_name EraSkin
extends RefCounted

# T-351: the §11 per-era PRESENTATION re-skin trigger, extracted from main.gd (which sits at its
# 1000-line lint cap). Given the local player's ground position it resolves the era (1 = inside the
# Ashmoor district, else 0) and applies it to BOTH re-skin surfaces the era owns:
#   - the ability VFX — VfxManager.set_era (frost bolt -> Gaslight Lance preset 19, heal ->
#     spiritualist-warm); a no-op when the era is unchanged, so it is cheap to call every tick.
#   - the held caster FOCUS — EntityVisuals.era (a bare mage/priest shows its sigil-cane/reliquary
#     as the default weapon in the district); the local player re-applies its gear on the crossing.
# Kit/mechanics never change (era-direction §11.1) — this only swaps the costume. The whole existing
# world is era 1, untouched. main.gd drives this from its throttled position tick.


# T-408: `wv` (the WorldView) is optional so the existing unit tests keep calling with 3 args; when
# present it rides the SAME era resolution to drive the per-region ATMOSPHERE (sky/fog/grade), so
# there is no second era detector.
static func update(pos: Vector3, vfx: VfxManager, local_player: Node, wv: Node = null) -> void:
	if vfx == null:
		return
	var era_id := 1 if WorldView.in_ashmoor_district(pos.x, pos.z) else 0
	vfx.set_era(era_id)
	if wv != null and wv.has_method("set_era_atmosphere"):
		wv.set_era_atmosphere(era_id)
	if EntityVisuals.era != era_id:
		EntityVisuals.era = era_id
		if local_player != null and local_player.has_method("reapply_gear_for_era"):
			local_player.reapply_gear_for_era()
