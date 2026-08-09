# T-063: pure effect resolvers — the combat verbs beyond M1's damage-only. RefCounted, all static,
# inputs never mutated; `rng` is the caller's injected generator. The executor dispatches on
# AbilityData.effect and applies the result to the right state (target hp for heal, the threat table
# for taunt/threat, combat_state for control). Heal scaling reuses stat_converter.heal_power
# (Intellect primary, Spirit secondary — staged in T-061).

extends RefCounted

const _STC = preload("res://scripts/combat/stat_converter.gd")


# Heal amount = (base + caster heal-power) * variance. Pure; the caller clamps to the target's max.
# Floored to a minimum of 1 so a landed heal always restores something (like damage's MIN_DAMAGE).
static func compute_heal(
	caster: CharacterStats, ability: AbilityData, rng: RandomNumberGenerator
) -> int:
	var raw: float = float(ability.heal_base) + _STC.heal_power(caster.int_val, caster.spirit_val)
	raw *= rng.randf_range(ability.variance_min, ability.variance_max)
	return maxi(1, int(floor(raw)))
