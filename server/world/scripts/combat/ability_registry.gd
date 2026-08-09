# Loads AbilityData from JSON files in a directory at server startup.
# Stateful — not a pure function. Instantiated once in main.gd._ready().

extends RefCounted

const _AD = preload("res://scripts/combat/ability_data.gd")

var _abilities: Dictionary = {}


func load_from_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("[ability_registry] cannot open dir: %s" % dir_path)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_file(dir_path.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()


func _load_file(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		push_error("[ability_registry] empty or missing: %s" % path)
		return
	var parsed = JSON.parse_string(text)
	if parsed == null:
		push_error("[ability_registry] JSON parse error: %s" % path)
		return
	var ab: AbilityData = _AD.new()
	ab.id = int(parsed.get("id", -1))
	ab.name = str(parsed.get("name", ""))
	ab.icon = str(parsed.get("icon", ""))  # T-422a: action-bar icon slug (client resolves the png)
	ab.cast_ticks = int(parsed.get("cast_ticks", 0))
	ab.triggers_gcd = bool(parsed.get("triggers_gcd", true))
	ab.off_gcd = bool(parsed.get("off_gcd", false))
	ab.mana_cost = int(parsed.get("mana_cost", 0))
	ab.stamina_cost = int(parsed.get("stamina_cost", 0))
	ab.resource_cost = int(parsed.get("resource_cost", 0))  # T-062: class-resource (rage|mana)
	ab.resource_gen = int(parsed.get("resource_gen", 0))
	ab.char_class = str(parsed.get("char_class", ""))  # T-063: class gate + effect verbs
	ab.trained = bool(parsed.get("trained", false))  # T-208: trainer-purchase gate
	ab.effect = str(parsed.get("effect", "damage"))
	ab.heal_base = int(parsed.get("heal_base", 0))
	ab.threat_amount = int(parsed.get("threat_amount", 0))
	ab.control_ticks = int(parsed.get("control_ticks", 0))
	ab.control_kind = str(parsed.get("control_kind", ""))
	ab.control_dr_category = str(parsed.get("control_dr_category", ""))
	ab.revive_hp_pct = float(parsed.get("revive_hp_pct", 0.35))  # T-364: resurrect params (data)
	ab.revive_mana_pct = float(parsed.get("revive_mana_pct", 0.35))
	ab.revive_sickness_ticks = int(parsed.get("revive_sickness_ticks", 200))
	ab.targets_friendly = bool(parsed.get("targets_friendly", false))
	ab.range_units = float(parsed.get("range_units", 0.0))
	ab.base_damage = int(parsed.get("base_damage", 0))
	ab.variance_min = float(parsed.get("variance_min", 0.85))
	ab.variance_max = float(parsed.get("variance_max", 1.0))
	ab.ranks = parsed.get("ranks", [])  # T-365: level-banded rank ladder (data-only scaling)
	ab.attacker_skills = parsed.get("attacker_skills", [])
	ab.mitigation_skills = parsed.get("mitigation_skills", [])
	ab.can_full_interrupt = bool(parsed.get("can_full_interrupt", false))
	ab.gcd_ticks_override = int(parsed.get("gcd_ticks_override", 0))
	ab.cooldown_ticks = int(parsed.get("cooldown_ticks", 0))
	ab.school = str(parsed.get("school", ""))
	ab.school_lock_ticks = int(parsed.get("school_lock_ticks", 0))
	ab.attacker_skill_coeffs = parsed.get("attacker_skill_coeffs", {})
	ab.mitigation_skill_coeffs = parsed.get("mitigation_skill_coeffs", {})
	ab.attacker_stat_coeffs = parsed.get("attacker_stat_coeffs", {})  # T-061: stat scaling (data)
	ab.mitigation_stat_coeffs = parsed.get("mitigation_stat_coeffs", {})
	ab.miss_chance = float(parsed.get("miss_chance", 0.0))
	ab.dodge_chance = float(parsed.get("dodge_chance", 0.0))
	ab.parry_chance = float(parsed.get("parry_chance", 0.0))
	ab.crit_chance = float(parsed.get("crit_chance", 0.0))
	ab.crit_multiplier = float(parsed.get("crit_multiplier", 2.0))
	ab.threat_multiplier = float(parsed.get("threat_multiplier", 1.0))
	if ab.id < 0:
		push_error("[ability_registry] ability missing id: %s" % path)
		return
	_abilities[ab.id] = ab


func get_ability(id: int) -> AbilityData:
	return _abilities.get(id, null)


func get_abilities_for_class(char_class: String) -> Array:
	# T-063: the class's kit — abilities tagged with this class, sorted by id for a stable action-bar
	# order. Shared "" basics (the auto-attack) are excluded; the client always has those.
	var out: Array = []
	for id in _abilities:
		var ab: AbilityData = _abilities[id]
		if ab.char_class == char_class:
			out.append(ab)
	out.sort_custom(func(a, b): return a.id < b.id)
	return out


func count() -> int:
	return _abilities.size()
