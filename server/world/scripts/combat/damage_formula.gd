# T-021: Data-driven damage formula — pure function, no OS time, no global state.
# Signature is final (established in T-020): callers and AbilityData shapes must not change.
#
# M1 NOTE: miss_chance, dodge_chance, parry_chance, crit_chance are flat per-ability
# constants (default 0.0 in M1). Per invariant #3 (skill-vector drives outcomes), the
# intent is that these eventually derive from attacker vs defender skill deltas (UO-style).
# Skill-based hit/miss/dodge/parry/crit is a deferred refinement — not built in M1.

extends RefCounted

const _SC = preload("res://scripts/server_config.gd")


class DamageResult:
	var amount: int = 0
	var outcome: String = "hit"
	var mitigated_amount: int = 0  # T-429: server-truth damage prevented by ratio mitigation

	static func hit(n: int, prevented: int = 0) -> DamageResult:
		var r = DamageResult.new()
		r.amount = n
		r.outcome = "hit"
		r.mitigated_amount = maxi(0, prevented)
		return r

	static func miss() -> DamageResult:
		var r = DamageResult.new()
		r.amount = 0
		r.outcome = "miss"
		return r

	static func dodge() -> DamageResult:
		var r = DamageResult.new()
		r.amount = 0
		r.outcome = "dodge"
		return r

	static func parry() -> DamageResult:
		var r = DamageResult.new()
		r.amount = 0
		r.outcome = "parry"
		return r

	static func crit(n: int, prevented: int = 0) -> DamageResult:
		var r = DamageResult.new()
		r.amount = n
		r.outcome = "crit"
		r.mitigated_amount = maxi(0, prevented)
		return r


static func compute_damage(
	attacker: CharacterStats,
	defender: CharacterStats,
	ability: AbilityData,
	rng: RandomNumberGenerator
) -> DamageResult:
	# Step 1 — Miss/dodge/parry: one roll covers all three thresholds.
	# M1 all rates default to 0.0 (always hit). Scaffold present for future refinement.
	var roll: float = rng.randf()
	if roll < ability.miss_chance:
		return DamageResult.miss()
	if roll < ability.miss_chance + ability.dodge_chance:
		return DamageResult.dodge()
	if roll < ability.miss_chance + ability.dodge_chance + ability.parry_chance:
		return DamageResult.parry()

	# Step 2 — Base damage + attacker skill bonus.
	var raw: float = float(ability.base_damage)
	for skill_id in ability.attacker_skill_coeffs:
		raw += float(attacker.get_skill(skill_id)) * float(ability.attacker_skill_coeffs[skill_id])
	# T-061: stat-based scaling — the real M4 driver (str->melee, int->spell, ...). Additive with
	# the skill scaffold above; empty coeffs (M1 abilities) leave damage unchanged.
	for stat_id in ability.attacker_stat_coeffs:
		raw += float(attacker.get_stat(stat_id)) * float(ability.attacker_stat_coeffs[stat_id])
	# T-399: gear attack power — a flat, class-agnostic term so a better weapon lifts every hit
	# (auto-attack AND ability). 0 for a naked player and for mobs, so those numbers never move.
	raw += float(attacker.attack_val)

	# Step 3 — Variance roll.
	raw *= rng.randf_range(ability.variance_min, ability.variance_max)

	# Step 4 — Ratio mitigation: K/(K+defense). Guarantees result > 0 for any finite defense.
	var defense: float = 0.0
	for skill_id in ability.mitigation_skill_coeffs:
		defense += (
			float(defender.get_skill(skill_id)) * float(ability.mitigation_skill_coeffs[skill_id])
		)
	# T-061: stat-based mitigation (schema-ready; no ability uses it until an armor/defense stat).
	for stat_id in ability.mitigation_stat_coeffs:
		defense += (
			float(defender.get_stat(stat_id)) * float(ability.mitigation_stat_coeffs[stat_id])
		)
	# T-399: gear armor — a flat, ability-agnostic defense term (worn armor mitigates ANY incoming
	# hit via the same K/(K+defense) ratio). 0 for a naked/unarmored target, so those hits are
	# unchanged; broken armor drops out upstream (effective_stats), so it stops protecting.
	defense += float(defender.armor_val)
	var k: float = _SC.MITIGATION_K
	var mitigated: float = raw * (k / (k + defense))

	# Step 5 — Crit: separate roll applied to the mitigated value before floor.
	var crit_roll: float = rng.randf()
	if crit_roll < ability.crit_chance:
		raw *= ability.crit_multiplier
		mitigated *= ability.crit_multiplier
		return DamageResult.crit(
			max(_SC.MIN_DAMAGE, int(floor(mitigated))),
			maxi(0, int(floor(raw)) - int(floor(mitigated)))
		)

	# Step 6 — Floor and MIN_DAMAGE clamp.
	return DamageResult.hit(
		max(_SC.MIN_DAMAGE, int(floor(mitigated))), maxi(0, int(floor(raw)) - int(floor(mitigated)))
	)
