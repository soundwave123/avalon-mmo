# T-341: The Hollowed Crypt undead family — headless unit tests.
# Covers: each undead mob JSON loads on the T-294 mob schema; stats sit in the L12-15 dungeon-TRASH
# band (tankier than open-world trash, well BELOW the elite tier the T-294 loader would multiply);
# every loot entry names a real item in the registry; the family reads distinctly (skeleton tanky,
# ghoul fast, shade evasive); and these are BASE silhouettes (render_kind empty) so the T-332 bosses
# can reuse them via render_kind. No open-world spawns are asserted — crypt spawns land with T-330.
# Pure loader inspection: no OS time, no engine loop, no network.

extends GutTest

const _ML = preload("res://scripts/combat/mob_loader.gd")

const _MOBS_DIR := "res://data/mobs"
const _ITEMS_PATH := "res://data/items/items.json"

# The elite tier the T-294 loader bakes (elite_hp_mult 5.0) lifts a base mob's HP into the hundreds;
# crypt trash must stay well under that so a 5-man group focus-kills them, not solos a boss.
const _ELITE_HP_FLOOR := 350

const _UNDEAD := [
	"skeletal_warrior.json",
	"crypt_ghoul.json",
	"restless_shade.json",
]


func _load(file_name: String):
	return _ML.load_from_file(_MOBS_DIR.path_join(file_name), 5000)


func _item_ids() -> Dictionary:
	var f := FileAccess.open(_ITEMS_PATH, FileAccess.READ)
	assert_not_null(f, "items.json must open")
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	var ids := {}
	for entry in parsed.get("items", []):
		ids[str(entry.get("id", ""))] = true
	return ids


func test_every_undead_mob_loads_as_nonelite_trash() -> void:
	for file_name in _UNDEAD:
		var mob = _load(file_name)
		assert_not_null(mob, "%s must load" % file_name)
		if mob == null:
			continue
		assert_true(mob.mob_id.begins_with("mob_"), "%s has a mob_ id alias" % file_name)
		assert_false(mob.elite, "%s is trash, not elite" % file_name)
		assert_between(mob.difficulty, 1, 3, "%s difficulty is trash-tier (1-3)" % file_name)
		# Tankier than open-world trash (wolf max_hp 80) but under the elite floor.
		assert_gt(mob.resources.max_hp, 0, "%s derived a positive max_hp" % file_name)
		assert_lt(
			mob.resources.max_hp, _ELITE_HP_FLOOR, "%s HP stays below the elite tier" % file_name
		)
		# Base silhouette: bosses (T-332) point their render_kind HERE, so these stay empty.
		assert_eq(mob.render_kind, "", "%s is a base silhouette (empty render_kind)" % file_name)


func test_undead_loot_names_only_real_items() -> void:
	var ids := _item_ids()
	for file_name in _UNDEAD:
		var mob = _load(file_name)
		assert_not_null(mob, "%s must load" % file_name)
		if mob == null:
			continue
		assert_gt(mob.loot.size(), 0, "%s drops something" % file_name)
		for entry in mob.loot:
			var item_id := str(entry.get("item_id", ""))
			assert_true(
				ids.has(item_id), "%s loot item %s exists in the registry" % [file_name, item_id]
			)


func test_family_reads_distinctly() -> void:
	var skel = _load("skeletal_warrior.json")
	var ghoul = _load("crypt_ghoul.json")
	var shade = _load("restless_shade.json")
	assert_not_null(skel)
	assert_not_null(ghoul)
	assert_not_null(shade)
	if skel == null or ghoul == null or shade == null:
		return
	# Skeleton is the backbone tank: the most HP of the three cores.
	assert_gt(skel.resources.max_hp, ghoul.resources.max_hp, "skeleton out-tanks the ghoul")
	assert_gt(skel.resources.max_hp, shade.resources.max_hp, "skeleton out-tanks the shade")
	# Ghoul is the fast charger: lower weapon_speed value = faster swing than the skeleton.
	assert_lt(
		ghoul.stats.weapon_speed, skel.stats.weapon_speed, "ghoul swings faster than the skeleton"
	)
	# Shade is the evasive drifter: the highest dodge of the family.
	assert_gt(
		shade.melee_ability.dodge_chance,
		skel.melee_ability.dodge_chance,
		"shade dodges more than the skeleton"
	)
	assert_gt(
		shade.melee_ability.dodge_chance,
		ghoul.melee_ability.dodge_chance,
		"shade dodges more than the ghoul"
	)


func test_unique_mob_type_ids() -> void:
	var seen := {}
	for file_name in _UNDEAD:
		var mob = _load(file_name)
		if mob == null:
			continue
		assert_false(seen.has(mob.mob_type_id), "%s mob_type_id is unique" % file_name)
		seen[mob.mob_type_id] = true
