class_name CharacterStats

# T-021: Character stats with M1 skill vector.
# Weapon speed sourced from item data in M2; default 1.0 for M1.
# Skills are clamped to [0, 100] in get_skill() per T2A era per-skill cap.

extends RefCounted

var weapon_speed: float = 1.0  # M1 stub: hardcoded default; M2 reads from equipped weapon
# T-061: full WoW-style attribute vector. str/int/dex existed (unused by the formula until T-061);
# spirit + stamina added so the per-class stat table (leveling.gd) can drive combat. Populated from
# master's class+level at spawn (see world/main.gd); 0 = no contribution.
var str_val: int = 0
var int_val: int = 0
var dex_val: int = 0
var spirit_val: int = 0
var stamina_val: int = 0
# T-399: gear-derived combat terms. `attack_val` = flat weapon/attack power added to outgoing
# damage; `armor_val` = flat armor added to the defender's mitigation. Both 0 for a naked player and
# for every mob (mobs carry no gear), so ungeared/mob damage is byte-identical to pre-T-399.
var attack_val: int = 0
var armor_val: int = 0
var skills: Dictionary = {}  # SkillID (String) -> int [0, 100]


# T-061/T-399: build a CharacterStats from master's stat vector (str/int/dex/spirit/stamina + the
# T-399 gear terms attack/armor). An empty vector (master degraded) falls back to the L1 flat-10
# primaries; gear terms default 0. Extracted here so world/main.gd stays under the 1000-line cap.
static func from_stat_vec(stat_vec: Dictionary) -> CharacterStats:
	var s := CharacterStats.new()
	if stat_vec.is_empty():
		s.str_val = 10
		s.int_val = 10
		s.dex_val = 10
		s.spirit_val = 10
		s.stamina_val = 10
		return s
	s.str_val = int(stat_vec.get("str", 0))
	s.int_val = int(stat_vec.get("int", 0))
	s.dex_val = int(stat_vec.get("dex", 0))
	s.spirit_val = int(stat_vec.get("spirit", 0))
	s.stamina_val = int(stat_vec.get("stamina", 0))
	s.attack_val = int(stat_vec.get("attack", 0))
	s.armor_val = int(stat_vec.get("armor", 0))
	return s


func get_skill(skill_id: String) -> int:
	return min(int(skills.get(skill_id, 0)), 100)


# T-061: uniform attribute accessor so damage_formula can apply ability `attacker_stat_coeffs`
# in a loop (mirrors get_skill). Unknown stat ids contribute 0. Stats are NOT skill-capped.
# T-399: attack/armor added for stat-sheet parity (damage_formula reads the fields directly). A
# dict dispatch keeps this a single return (gdlint max-returns) as the stat set grows.
func get_stat(stat_id: String) -> int:
	var by_id := {
		"str": str_val,
		"int": int_val,
		"dex": dex_val,
		"spirit": spirit_val,
		"stamina": stamina_val,
		"attack": attack_val,
		"armor": armor_val,
	}
	return int(by_id.get(stat_id, 0))
