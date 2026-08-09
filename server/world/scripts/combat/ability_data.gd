# T-018: Ability data schema — data-driven, not hardcoded.
# Ability definitions live in server/world/data/abilities/ JSON files.
# This class is the in-memory shape; load from data at startup.
#
# NOTE: Starting with JSON format (easy to edit without Godot editor).
# May migrate to .tres Resource if editor workflow demands it.

class_name AbilityData

extends RefCounted

var id: int
var name: String
# T-422a: icon slug -> client res://assets/icons/abilities/<icon>.png ("" = text-glyph fallback)
var icon: String = ""
var cast_ticks: int = 0  # 0 = instant
var triggers_gcd: bool = true
var off_gcd: bool = false
var mana_cost: int
var stamina_cost: int
# T-062: class-resource cost/gen (rage|mana; kind implied by the caster's class). The server
# validates resource_cost against the caster's class resource on use_ability; resource_gen is
# optional explicit generation (the core rage build is systemic - damage dealt/taken).
var resource_cost: int = 0
var resource_gen: int = 0
# T-063: class identity + effect verb (beyond M1's damage-only). `char_class` ("" = any/mob) gates
# who may use it; `effect` picks the server resolver. heal/threat/control carry their own params.
var char_class: String = ""  # "warrior" | "mage" | "priest" | "" (any — mobs/shared)
var trained: bool = false  # T-208: gated behind a trainer purchase (kit filter)
var effect: String = "damage"  # "damage" | "heal" | "threat" | "taunt" | "control"
var heal_base: int = 0  # heal: base restored before int/spirit scaling (stat_converter.heal_power)
var threat_amount: int = 0  # threat: flat threat added (taunt forces the caster to top regardless)
var control_ticks: int = 0  # control: root/stun duration in ticks
var control_kind: String = ""  # control: "root" | "stun"
# T-434: hard-CC category for PvP diminishing returns (empty = no DR tracking).
var control_dr_category: String = ""
# T-364: resurrect params (data-tunable) — restore a DEAD ally at the caster at a fraction of max
# HP/mana, with a revive-sickness debuff window (the tuning knob; magnitude is ServerConfig).
var revive_hp_pct: float = 0.35
var revive_mana_pct: float = 0.35
var revive_sickness_ticks: int = 200
var targets_friendly: bool = false  # heal/buff: target must be friendly/self, not an enemy
var range_units: float
var base_damage: int
var variance_min: float = 0.85
var variance_max: float = 1.00
# T-365: rank ladder — ascending list of
# {min_level, base_damage?, heal_base?, mana_cost?, resource_cost?}. The character's rank is DERIVED
# from their authoritative level (never client-supplied); each entry overrides only the scalars it
# names, falling back to the rank-1 top-level fields. Empty = flat (no scaling).
var ranks: Array = []
var attacker_skills: Array  # Array[SkillID]
var mitigation_skills: Array
var can_full_interrupt: bool = false  # D1: full-interrupt trigger; no ability sets true in M1
var gcd_ticks_override: int = 0  # 0 = use global GCD_TICKS from ServerConfig
# T-434: server-owned per-ability cooldown + interrupt school lock. `school` describes the
# CASTING ability; a full interrupt stamps that school into the target's CombatState lock table.
var cooldown_ticks: int = 0
var school: String = ""
var school_lock_ticks: int = 0

# T-021: Damage formula coefficients (data-driven, loaded from JSON).
# M1 NOTE: miss/dodge/parry/crit are flat per-ability constants (default 0.0).
# Per invariant #3, these should eventually derive from attacker vs defender
# skill deltas (UO-style). Skill-based hit/miss calc is a deferred refinement.
var attacker_skill_coeffs: Dictionary = {}  # SkillID -> float
var mitigation_skill_coeffs: Dictionary = {}  # SkillID -> float

# T-061: stat-based scaling - the real combat driver in M4 (the skill coeffs above are an
# additive M1 scaffold). Same shape as the skill coeffs so the formula applies both in one pass.
# Data-driven per ability/class: a Warrior strike scales {"str": x}, a Mage nuke {"int": y}; empty
# means no scaling. mitigation_stat_coeffs is schema-ready for a future armor/defense stat (unused).
var attacker_stat_coeffs: Dictionary = {}  # StatID ("str"/"int"/"dex"/"spirit"/"stamina") -> float
var mitigation_stat_coeffs: Dictionary = {}  # StatID -> float
var miss_chance: float = 0.0
var dodge_chance: float = 0.0
var parry_chance: float = 0.0
var crit_chance: float = 0.0
var crit_multiplier: float = 2.0

# T-024: Threat multiplier — multiplies damage to produce threat.
# 1.0 = normal threat, 2.0 = double threat (e.g. spell casts).
var threat_multiplier: float = 1.0


func get_attacker_coeff(skill_id: String) -> float:
	return float(attacker_skill_coeffs.get(skill_id, 0.0))


func get_mitigation_coeff(skill_id: String) -> float:
	return float(mitigation_skill_coeffs.get(skill_id, 0.0))


func get_attacker_stat_coeff(stat_id: String) -> float:
	return float(attacker_stat_coeffs.get(stat_id, 0.0))


func get_mitigation_stat_coeff(stat_id: String) -> float:
	return float(mitigation_stat_coeffs.get(stat_id, 0.0))


# T-365: the highest rank (1-based) a character of `level` qualifies for; 1 when there is no ladder.
# Ranks unlock at their `min_level` — automatic level-band cadence, not a purchase.
func rank_for_level(level: int) -> int:
	var r: int = 1
	for i in ranks.size():
		if level >= int(ranks[i].get("min_level", 1)):
			r = i + 1
	return r


# T-365: an effective copy scaled to the character's level. Returns SELF (no allocation) when the
# ability has no rank ladder. The server calls this with the session-held level; the client has no
# channel to name a rank, so a higher rank is unreachable below its band by construction.
func effective_at_level(level: int) -> AbilityData:
	if ranks.is_empty():
		return self
	var entry: Dictionary = ranks[rank_for_level(level) - 1]
	var out: AbilityData = _copy()
	out.base_damage = int(entry.get("base_damage", base_damage))
	out.heal_base = int(entry.get("heal_base", heal_base))
	out.mana_cost = int(entry.get("mana_cost", mana_cost))
	out.resource_cost = int(entry.get("resource_cost", resource_cost))
	out.cooldown_ticks = int(entry.get("cooldown_ticks", cooldown_ticks))
	out.control_ticks = int(entry.get("control_ticks", control_ticks))
	out.school_lock_ticks = int(entry.get("school_lock_ticks", school_lock_ticks))
	return out


# T-365: full-field duplicate so a rank-scaled cast never mutates the shared registry instance.
func _copy() -> AbilityData:
	var c := AbilityData.new()
	c.id = id
	c.name = name
	c.icon = icon
	c.cast_ticks = cast_ticks
	c.triggers_gcd = triggers_gcd
	c.off_gcd = off_gcd
	c.mana_cost = mana_cost
	c.stamina_cost = stamina_cost
	c.resource_cost = resource_cost
	c.resource_gen = resource_gen
	c.char_class = char_class
	c.trained = trained
	c.effect = effect
	c.heal_base = heal_base
	c.threat_amount = threat_amount
	c.control_ticks = control_ticks
	c.control_kind = control_kind
	c.control_dr_category = control_dr_category
	c.revive_hp_pct = revive_hp_pct
	c.revive_mana_pct = revive_mana_pct
	c.revive_sickness_ticks = revive_sickness_ticks
	c.targets_friendly = targets_friendly
	c.range_units = range_units
	c.base_damage = base_damage
	c.variance_min = variance_min
	c.variance_max = variance_max
	c.ranks = ranks
	c.attacker_skills = attacker_skills
	c.mitigation_skills = mitigation_skills
	c.can_full_interrupt = can_full_interrupt
	c.gcd_ticks_override = gcd_ticks_override
	c.cooldown_ticks = cooldown_ticks
	c.school = school
	c.school_lock_ticks = school_lock_ticks
	c.attacker_skill_coeffs = attacker_skill_coeffs
	c.mitigation_skill_coeffs = mitigation_skill_coeffs
	c.attacker_stat_coeffs = attacker_stat_coeffs
	c.mitigation_stat_coeffs = mitigation_stat_coeffs
	c.miss_chance = miss_chance
	c.dodge_chance = dodge_chance
	c.parry_chance = parry_chance
	c.crit_chance = crit_chance
	c.crit_multiplier = crit_multiplier
	c.threat_multiplier = threat_multiplier
	return c
