# T-044 (refactor): mob construction extracted from world/main.gd to keep it under the file-length
# limit. Pure data loading — opens a mob JSON file and builds a MobData. No game logic, no per-tick.

extends RefCounted

const _SC = preload("res://scripts/server_config.gd")  # T-411: default respawn dwell
const _MD = preload("res://scripts/combat/mob_data.gd")
const _CSTATS = preload("res://scripts/combat/character_stats.gd")
const _CR = preload("res://scripts/combat/combat_resources.gd")
const _ADAT = preload("res://scripts/combat/ability_data.gd")
const _MAI = preload("res://scripts/combat/mob_ai.gd")
const _CS = preload("res://scripts/combat/combat_state.gd")
const _SRESP = preload("res://scripts/spawn_respawn.gd")  # T-414: shared respawn math (was inline)

# T-411: worst-case dormant cycles before a rare's forced return (see next_respawn_ticks).
const _RARE_CYCLE_CAP := 12


# T-073/T-065: read spawns.json + build every spawned mob. Returns {entity_id: MobData},
# or an empty Dictionary on a malformed/missing spawn table (caller fails loud).
static func load_spawn_table(dir_path: String) -> Dictionary:
	return load_spawn_table_filtered(dir_path, null, [])


# T-594: load only the mobs whose spawn ground falls in an ACTIVE terrain region (per WorldRegions
# nearest-origin) — the per-zone RESIDENCY hook the continent program grows into. `allowed` is a set
# of region indices (an Array); EMPTY (or a null `regions` table) loads EVERYTHING, so the P1 boot
# path (load_spawn_table) is byte-identical to before — at 24 mobs the whole table stays resident;
# the sleeping-zone GATE, not construction, is the P1 perf floor. The filter is what a 150 km² world
# uses to construct only the near-player zones' mobs; lazy per-region file loading on wake (so a
# never-visited zone's spawn files never open) is the documented follow-on once the zone count is
# large enough to matter.
static func load_spawn_table_filtered(dir_path: String, regions, allowed: Array) -> Dictionary:
	var mobs: Dictionary = {}
	var entries: Array = _read_spawn_entries(dir_path)
	var filtering: bool = regions != null and not allowed.is_empty()
	for entry in entries:
		var mob_file: String = str(entry.get("mob_file", ""))
		var base_id: int = int(entry.get("entity_id_base", -1))
		var positions: Array = entry.get("positions", [])
		if mob_file == "" or base_id < 1000 or positions.is_empty():
			printerr("[mob_loader] skipping malformed spawn entry: %s" % str(entry))
			continue
		# T-411: rare/VR spawn tuning is authored on the ENTRY (fail-open — an entry that omits
		# these fields loads exactly as before: always-present, global respawn dwell).
		var spawn_chance: float = clampf(float(entry.get("spawn_chance", 1.0)), 0.0, 1.0)
		var respawn_ticks: int = maxi(1, int(entry.get("respawn_ticks", _SC.MOB_RESPAWN_TICKS)))
		for i in range(positions.size()):
			var pos: Array = positions[i]
			# T-594: keep the entity_id stable per position slot even when a region is filtered out,
			# so residency never renumbers a mob (kill-credit aliases + threat keys stay valid).
			if filtering and not allowed.has(regions.region_index(float(pos[0]), float(pos[1]))):
				continue
			var mob = load_from_file(dir_path.path_join(mob_file), base_id + i)
			if mob == null:
				continue
			mob.position = Vector3(float(pos[0]), float(pos[1]), 0.0)
			mob.spawn_position = mob.position
			mob.spawn_chance = spawn_chance
			mob.respawn_ticks = respawn_ticks
			mobs[mob.entity_id] = mob
	return mobs


# T-594: the distinct terrain-region indices (into `regions`) that hold at least one spawn — the set
# of zones a continent-scale loader would keep spawn files for. Pure read of spawns.json.
static func spawn_region_ids(dir_path: String, regions) -> Array:
	var seen: Dictionary = {}
	for entry in _read_spawn_entries(dir_path):
		for pos in entry.get("positions", []):
			if pos is Array and (pos as Array).size() >= 2:
				seen[regions.region_index(float(pos[0]), float(pos[1]))] = true
	return seen.keys()


# Parse spawns.json into its raw entry Array ([] on a missing/malformed table). Shared by the loader
# and the region-index query so the file is read+validated in exactly one place.
static func _read_spawn_entries(dir_path: String) -> Array:
	var file := FileAccess.open(dir_path.path_join("spawns.json"), FileAccess.READ)
	if file == null:
		printerr("[mob_loader] cannot open %s/spawns.json" % dir_path)
		return []
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not (parsed.get("spawns", null) is Array):
		printerr('[mob_loader] spawns.json malformed (need {"spawns": [...]})')
		return []
	return parsed["spawns"]


# T-411: how long until this mob's next appearance, in ticks. T-414: the geometric variable-ratio
# math moved to spawn_respawn.gd so gathering nodes ride the SAME machinery (generalize, don't
# duplicate) — this wrapper keeps the mob-shaped call site and the rare cycle cap.
static func next_respawn_ticks(mob, rng) -> int:
	return _SRESP.next_ticks(int(mob.respawn_ticks), float(mob.spawn_chance), rng, _RARE_CYCLE_CAP)


# Returns a built MobData, or null on read/parse failure.
static func load_from_file(path: String, entity_id: int):
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("[mob_loader] failed to open mob definition: %s" % path)
		return null
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	if data == null:
		printerr("[mob_loader] failed to parse mob definition: %s" % path)
		return null

	var mob = _MD.new()
	mob.entity_id = entity_id
	mob.mob_type_id = int(data.get("mob_type_id", 1))
	mob.mob_id = str(data.get("mob_id", ""))  # T-042: alias for quest kill matching
	mob.name = str(data.get("name", "Mob"))
	var spawn_x: float = float(data.get("spawn_x", 10.0))
	var spawn_y: float = float(data.get("spawn_y", 10.0))
	mob.position = Vector3(spawn_x, spawn_y, 0.0)
	mob.spawn_position = Vector3(spawn_x, spawn_y, 0.0)
	mob.aggro_radius = float(data.get("aggro_radius", 5.0))
	mob.leash_radius = float(data.get("leash_radius", 15.0))
	mob.melee_range = float(data.get("melee_range", 2.0))
	# T-534: optional per-mob chase-speed multiplier (default 1.01 = player run speed +1%).
	mob.speed_mult = float(data.get("speed_mult", _SC.MOB_CHASE_SPEED_MULT))
	mob.is_dummy = bool(data.get("dummy", false))  # T-516: static, passive practice target
	mob.non_lethal = bool(data.get("non_lethal", false))  # T-560: trainer that can bruise but not kill
	# T-564: passive until attacked (still fully aggros on threat — see mob_ai._tick_idle).
	mob.retaliate_only = bool(data.get("retaliate_only", false))
	mob.ai_state = _MAI.MobAIState.IDLE
	mob.current_target_id = -1
	mob.combat_state = _CS.new()

	var stats := _CSTATS.new()
	stats.str_val = int(data.get("str", 10))
	stats.int_val = int(data.get("int", 10))
	stats.dex_val = int(data.get("dex", 10))
	# T-061: stamina drives max HP, spirit drives regen; default 10 so an unspecified mob ~ L1 player.
	stats.stamina_val = int(data.get("stamina", 10))
	stats.spirit_val = int(data.get("spirit", 10))
	stats.weapon_speed = float(data.get("weapon_speed", 1.0))
	var skills_data = data.get("skills", {})
	for skill_id in skills_data:
		stats.skills[skill_id] = int(skills_data.get(skill_id, 0))
	mob.stats = stats

	var cr := _CR.new()
	cr.derive_from_stats(stats)
	mob.resources = cr

	var ab := _ADAT.new()
	ab.id = 0  # reserved for mob auto-attack
	ab.name = str(data.get("name", "Mob")) + " Melee"
	ab.cast_ticks = 0
	ab.triggers_gcd = false
	ab.mana_cost = 0
	ab.stamina_cost = 0
	ab.range_units = mob.melee_range
	ab.base_damage = int(data.get("base_damage", 5))
	ab.variance_min = float(data.get("variance_min", 0.85))
	ab.variance_max = float(data.get("variance_max", 1.0))
	var att = data.get("attacker_skill_coeffs", {})
	for k in att:
		ab.attacker_skill_coeffs[k] = float(att.get(k, 0.0))
	var mit = data.get("mitigation_skill_coeffs", {})
	for k in mit:
		ab.mitigation_skill_coeffs[k] = float(mit.get(k, 0.0))
	# T-061: stat coeffs (parity with player abilities; absent on the dummy -> empty/no scaling).
	var att_stat = data.get("attacker_stat_coeffs", {})
	for sk in att_stat:
		ab.attacker_stat_coeffs[sk] = float(att_stat.get(sk, 0.0))
	var mit_stat = data.get("mitigation_stat_coeffs", {})
	for sk in mit_stat:
		ab.mitigation_stat_coeffs[sk] = float(mit_stat.get(sk, 0.0))
	ab.miss_chance = float(data.get("miss_chance", 0.0))
	ab.dodge_chance = float(data.get("dodge_chance", 0.0))
	ab.parry_chance = float(data.get("parry_chance", 0.0))
	ab.crit_chance = float(data.get("crit_chance", 0.0))
	ab.crit_multiplier = float(data.get("crit_multiplier", 2.0))
	ab.threat_multiplier = float(data.get("threat_multiplier", 1.0))
	mob.melee_ability = ab

	# T-073: data-driven loot table (validated against the item registry by content-lint).
	var loot = data.get("loot", [])
	mob.loot = loot if loot is Array else []

	# T-232: difficulty (1-5) drives the rarity-weighted loot roll; absent -> 1 (dummy-tier).
	mob.difficulty = clampi(int(data.get("difficulty", 1)), 1, 5)

	# T-620: mob-kill XP pool + level. WoW-shape formula (mobLevel*MOB_XP_PER_LEVEL+MOB_XP_BASE,
	# doubled for elites) replaces the old flat authored "xp" JSON value. Two hard-pinned exceptions
	# stay at zero regardless of level/formula: is_dummy (a static practice target must never become
	# a free-XP farm) and any mob that explicitly authors "xp": 0 (e.g. training_effigy.json, a
	# non-lethal retaliate-only tutorial target with no real progression intent). Granted master-side
	# (mob_xp.gd) via the kill-credit snapshot; mob_level also drives the gray cutoff there.
	mob.mob_level = maxi(1, int(data.get("level", 1)))
	var elite_for_xp: bool = bool(data.get("elite", false))
	if mob.is_dummy or (data.has("xp") and int(data.get("xp", 0)) <= 0):
		mob.xp = 0
	else:
		mob.xp = _SC.MOB_XP_PER_LEVEL * mob.mob_level + _SC.MOB_XP_BASE
		if elite_for_xp:
			mob.xp *= _SC.MOB_XP_ELITE_MULT

	# T-080: patrol radius (0 = stationary — dummies and rooted plants stay put).
	mob.patrol_radius = float(data.get("patrol_radius", 0.0))

	# T-350: ranged/kite profile from the T-349 "_ranged" handoff block. Absent -> pure melee
	# (mob.ranged stays false, every field inert). When present, the mob fires a hitscan inside
	# its [min,max] band and kites to hold it (mob_ai._tick_ranged). melee_range is authored to
	# the band max in the JSON so the shared MELEE-state entry/fire gate already reads "in range".
	var ranged_block = data.get("_ranged", null)
	if ranged_block is Dictionary:
		mob.ranged = true
		mob.ranged_min = float(ranged_block.get("min_range", 8.0))
		mob.ranged_max = float(ranged_block.get("max_range", 15.0))
		mob.ranged_attack = str(ranged_block.get("attack", "revolver"))
		mob.ranged_burst = maxi(1, int(ranged_block.get("burst", 1)))

	# T-294: elite tier. Data-driven; bake the HP/damage multipliers into the derived resources and
	# the melee ability so the downstream damage/AI math needs no elite-awareness. A normal mob
	# (elite absent/false) is untouched. render_kind lets an elite reuse a base creature silhouette
	# while keeping mob_id as a UNIQUE kill-credit alias (T-293 bounties target that alias).
	mob.elite = bool(data.get("elite", false))
	mob.render_kind = str(data.get("render_kind", ""))
	if mob.elite:
		var hp_mult: float = maxf(1.0, float(data.get("elite_hp_mult", 5.0)))
		var dmg_mult: float = maxf(1.0, float(data.get("elite_damage_mult", 2.5)))
		cr.max_hp = int(round(float(cr.max_hp) * hp_mult))
		cr.hp = cr.max_hp
		ab.base_damage = int(round(float(ab.base_damage) * dmg_mult))
		# Enrage: a brief low-HP damage buff, applied on the existing swing path by mob_ai.
		mob.enrage_threshold = clampf(float(data.get("enrage_threshold", 0.3)), 0.0, 1.0)
		mob.enrage_mult = maxf(1.0, float(data.get("enrage_mult", 1.5)))

	# T-332: Hollowed Crypt boss mechanic (one per boss beyond enrage). Data-only; a normal mob
	# (boss_mechanic absent) reads every default and stays inert. boss_mechanics.gd advances these;
	# instance_service.tick_bosses resolves the summon/dirge/phase against the live world.
	mob.boss_mechanic = str(data.get("boss_mechanic", ""))
	mob.control_immune = bool(data.get("control_immune", false))
	mob.interrupt_immune = bool(data.get("interrupt_immune", false))
	if mob.boss_mechanic != "":
		mob.mechanic_cadence = int(data.get("mechanic_cadence", 0))
		mob.add_mob_file = str(data.get("add_mob_file", ""))
		mob.add_render_kind = str(data.get("add_render_kind", ""))
		var anchors = data.get("add_anchors", [])
		mob.add_anchors = anchors if anchors is Array else []
		mob.max_adds = int(data.get("max_adds", 0))
		mob.dirge_channel_ticks = int(data.get("dirge_channel_ticks", 0))
		mob.dirge_damage = int(data.get("dirge_damage", 0))
		mob.dirge_radius = float(data.get("dirge_radius", 0.0))
		mob.dirge_interrupt_damage = int(data.get("dirge_interrupt_damage", 0))
		mob.phase2_threshold = clampf(float(data.get("phase2_threshold", 0.0)), 0.0, 1.0)
		mob.phase2_cadence = int(data.get("phase2_cadence", 0))
	mob.render_scale = maxf(0.1, float(data.get("render_scale", 1.0)))

	return mob
