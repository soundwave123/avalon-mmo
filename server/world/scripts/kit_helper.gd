class_name KitHelper
extends RefCounted

# T-208: kit assembly split from world main (file-size budget). Builds the class-kit
# payload rows, filtering trained abilities behind their trainer purchase.
# T-422c: an optional `layout` (saved ability-id order) re-orders the finished kit so the class_kit
# the world ships at spawn is ALREADY in the player's saved slot order (client renders it as-is).

const _BLO = preload("res://scripts/bar_layout_ops.gd")


static func build_kit(registry, char_class: String, unlocked: Array, layout: Array = []) -> Array:
	# JSON-parsed unlock ids arrive as floats; Array.has is type-strict (203 != 203.0)
	var unlocked_ids: Array = []
	for u in unlocked:
		unlocked_ids.append(int(u))
	var kit: Array = []
	for ab in registry.get_abilities_for_class(char_class):
		if ab.trained and not (ab.id in unlocked_ids):
			continue
		(
			kit
			. append(
				{
					"id": ab.id,
					"name": ab.name,
					"icon": ab.icon,  # T-422a: action-bar icon slug (client -> assets/icons/abilities)
					"effect": ab.effect,
					"cast_ticks": ab.cast_ticks,
					"resource_cost": ab.resource_cost,
					"mana_cost": ab.mana_cost,
					"range_units": ab.range_units,
					"cooldown_ticks": ab.cooldown_ticks,  # display only; server state remains authority
					"control_kind": ab.control_kind,
					"control_ticks": ab.control_ticks,
					# T-422b: spellbook tooltip fields — server-authored DISPLAY data the client only
					# renders (damage/heal range + stat coefficient). The client never re-derives a
					# gameplay number from these; the executor rolls the authoritative value server-side.
					"base_damage": ab.base_damage,
					"heal_base": ab.heal_base,
					"attacker_stat_coeffs": ab.attacker_stat_coeffs,
					"variance_min": ab.variance_min,
					"variance_max": ab.variance_max,
				}
			)
		)
	return _BLO.order_kit(kit, layout)  # T-422c: apply the saved slot order (no-op when empty)
