# T-349: The Ashmoor Syndicate street-tier mob family — headless unit tests.
# Covers: the WAVE-1 melee three (legbreaker / constable / seance warden) load on the T-294 mob
# schema in the L20-24 Ashmoor band (a step above the L12-15 crypt trash, well BELOW the elite
# tier); every loot entry (all five, incl. the pending gun mobs) names a real registry item; the
# family reads distinctly (legbreaker tanks, warden evades, constable swings faster than the
# bruiser); the WAVE-2 gun mobs (gunsel/torpedo) are DATA STUBS marked _pending T-350 and are NOT
# spawned; and the wave-1 spawns sit clear of the rift-arrival plaza (the T-330 vestibule lesson).
# Pure loader/JSON inspection: no OS time, no engine loop, no network.

extends GutTest

const _ML = preload("res://scripts/combat/mob_loader.gd")

const _MOBS_DIR := "res://data/mobs"
const _ITEMS_PATH := "res://data/items/items.json"
const _SPAWNS_PATH := "res://data/mobs/spawns.json"

# The T-294 elite tier (elite_hp_mult) lifts a base mob's HP into the hundreds; a non-elite street
# goon must stay well under that so a fresh Era-2 arrival can solo one and a pack is the threat.
const _ELITE_HP_FLOOR := 350
# L20-24 Ashmoor band (HP = 50 + stamina*5): the melee three land 170-220 — above the L12-15 crypt
# trash (130-200) yet solo-fair for an L15-20 arrival in Era-1 gear.
const _BAND_HP_MIN := 160
const _BAND_HP_MAX := 260

# ashmoor.json arrival plaza (instance_service.ASHMOOR_ARRIVAL). A fresh arrival must not be
# instantly swarmed. T-402 lifted the aggro model to level-relative WoW reach (~16-20m base), so the
# clearance grew past the worst-case cap; test_spawn_spacing.gd owns the full pull-spacing invariant.
const _ARRIVAL := Vector2(-420.0, -5.0)
const _ARRIVAL_CLEARANCE := 24.0
# ashmoor.json footprint (the ±140 spike corner at (-420,0)).
const _FOOT_X_MIN := -490.0
const _FOOT_X_MAX := -350.0
const _FOOT_Y_MIN := -70.0
const _FOOT_Y_MAX := 70.0

const _WAVE1 := [
	"syndicate_legbreaker.json",
	"constable_take.json",
	"seance_warden.json",
]
# T-350 flipped these LIVE (were pending T-349 stubs): the ranged gun kiters.
const _WAVE2 := [
	"syndicate_gunsel.json",
	"syndicate_torpedo.json",
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


func _spawn_entries() -> Array:
	var f := FileAccess.open(_SPAWNS_PATH, FileAccess.READ)
	assert_not_null(f, "spawns.json must open")
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed.get("spawns", []) if parsed is Dictionary else []


func test_wave1_melee_loads_in_band() -> void:
	for file_name in _WAVE1:
		var mob = _load(file_name)
		assert_not_null(mob, "%s must load" % file_name)
		if mob == null:
			continue
		assert_true(mob.mob_id.begins_with("mob_"), "%s has a mob_ id alias" % file_name)
		assert_false(mob.elite, "%s is street trash, not elite" % file_name)
		assert_between(mob.difficulty, 1, 3, "%s difficulty is trash-tier (1-3)" % file_name)
		assert_between(
			mob.resources.max_hp,
			_BAND_HP_MIN,
			_BAND_HP_MAX,
			"%s HP sits in the L20-24 Ashmoor band" % file_name
		)
		assert_lt(
			mob.resources.max_hp, _ELITE_HP_FLOOR, "%s HP stays below the elite tier" % file_name
		)
		# Base silhouette: broadcast kind falls back to mob_id (the T-352 bounty kill-credit alias).
		assert_eq(mob.render_kind, "", "%s broadcasts by mob_id (empty render_kind)" % file_name)


func test_loot_names_only_real_items() -> void:
	var ids := _item_ids()
	for file_name in _WAVE1 + _WAVE2:
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
	var leg = _load("syndicate_legbreaker.json")
	var con = _load("constable_take.json")
	var war = _load("seance_warden.json")
	if leg == null or con == null or war == null:
		assert_not_null(leg)
		assert_not_null(con)
		assert_not_null(war)
		return
	# Legbreaker is the bruiser: the most HP of the wave-1 three.
	assert_gt(leg.resources.max_hp, con.resources.max_hp, "legbreaker out-tanks the constable")
	assert_gt(leg.resources.max_hp, war.resources.max_hp, "legbreaker out-tanks the warden")
	# Constable's disciplined baton swings faster than the bruiser's heavy club (lower speed = faster).
	assert_lt(
		con.stats.weapon_speed,
		leg.stats.weapon_speed,
		"constable swings faster than the legbreaker"
	)
	# The warden is the squishy evader: highest dodge of the family.
	assert_gt(
		war.melee_ability.dodge_chance,
		leg.melee_ability.dodge_chance,
		"warden dodges more than the legbreaker"
	)
	assert_gt(
		war.melee_ability.dodge_chance,
		con.melee_ability.dodge_chance,
		"warden dodges more than the constable"
	)


func test_gun_mobs_are_ranged() -> void:
	# T-350: the gun mobs now load with a live ranged/kite profile off the "_ranged" block.
	for file_name in _WAVE2:
		var mob = _load(file_name)
		assert_not_null(mob, "%s must load" % file_name)
		if mob == null:
			continue
		assert_true(mob.ranged, "%s is a ranged mob" % file_name)
		assert_gt(mob.ranged_max, mob.ranged_min, "%s has a valid firing band" % file_name)
		assert_gt(mob.ranged_min, 0.0, "%s kites (positive min range)" % file_name)
		assert_ne(mob.ranged_attack, "", "%s names a ranged attack (client VFX/audio)" % file_name)
	# The revolver is a single shot; the tommy fires a heavier 3-shot burst.
	var gunsel = _load("syndicate_gunsel.json")
	var torpedo = _load("syndicate_torpedo.json")
	if gunsel != null and torpedo != null:
		assert_eq(gunsel.ranged_burst, 1, "the revolver fires one shot per window")
		assert_gt(torpedo.ranged_burst, gunsel.ranged_burst, "the tommy burst is heavier")
		assert_true(torpedo.elite, "torpedo is elite (T-294 chassis)")
		# A pure-melee mob is untouched: the ranged profile stays off.
		var leg = _load("syndicate_legbreaker.json")
		assert_false(leg.ranged, "the melee legbreaker is not ranged")


func test_family_is_spawned_clear_of_arrival() -> void:
	var spawned := {}
	for entry in _spawn_entries():
		spawned[str(entry.get("mob_file", ""))] = entry.get("positions", [])
	# T-350: the full family is spawned now — the melee three AND the two gun kiters.
	for file_name in _WAVE1 + _WAVE2:
		assert_true(spawned.has(file_name), "%s is spawned in Ashmoor" % file_name)
	# Every spawn is inside the Ashmoor footprint and clear of the arrival plaza.
	for file_name in _WAVE1 + _WAVE2:
		for pos in spawned.get(file_name, []):
			var p := Vector2(float(pos[0]), float(pos[1]))
			assert_between(
				p.x, _FOOT_X_MIN, _FOOT_X_MAX, "%s x in the Ashmoor footprint" % file_name
			)
			assert_between(
				p.y, _FOOT_Y_MIN, _FOOT_Y_MAX, "%s y in the Ashmoor footprint" % file_name
			)
			assert_gt(
				p.distance_to(_ARRIVAL),
				_ARRIVAL_CLEARANCE,
				"%s spawn %s is clear of the arrival plaza" % [file_name, str(pos)]
			)


func test_unique_mob_type_ids() -> void:
	var seen := {}
	for file_name in _WAVE1 + _WAVE2:
		var mob = _load(file_name)
		if mob == null:
			continue
		assert_false(seen.has(mob.mob_type_id), "%s mob_type_id is unique" % file_name)
		seen[mob.mob_type_id] = true
	assert_eq(seen.size(), 5, "five distinct Syndicate mob_type_ids")
