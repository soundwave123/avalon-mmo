extends GutTest

# T-594: sleeping zones — the server perf floor. Proves (a) the awake set is exactly the regions
# players occupy, (b) an open-world mob in an empty region is skipped (zero ticks, the whole point),
# (c) instance mobs always tick, (d) a soak spread across N regions ticks ONLY those regions' mobs
# (the tick-time budget as a deterministic work-count), (e) the optional origin wake margin, and
# (f) the per-active-region spawn-table loader constructs only the allowed zones while keeping the
# always-load boot byte-identical.

const _SZ = preload("res://scripts/sleeping_zones.gd")
const _WR = preload("res://scripts/world_regions.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _MD = preload("res://scripts/combat/mob_data.gd")

const MOBS_DIR := "res://data/mobs"


func _regions():
	return _WR.load_default()


# All shipped open-world mobs, grouped by their WorldRegions region id (via nearest-origin).
func _mobs_by_region_id() -> Dictionary:
	var wr = _regions()
	var mobs: Dictionary = _ML.load_spawn_table(MOBS_DIR)
	var by_id: Dictionary = {}
	for eid in mobs:
		var m = mobs[eid]
		var rid: String = wr.region_id_at(m.position.x, m.position.y)
		by_id[rid] = by_id.get(rid, 0) + 1
	return by_id


# ---- (a) the awake set is the regions players occupy ----------------------------------------
func test_awake_set_is_the_regions_players_stand_in() -> void:
	var wr = _regions()
	# One player at the Wold origin, one deep in Ashmoor City.
	var grounds := [Vector2(0.0, 0.0), Vector2(-440.0, 20.0)]
	var awake: Dictionary = _SZ.awake_regions(grounds, wr, 0.0)
	assert_true(awake.has(wr.region_index(0.0, 0.0)), "the Wold wakes (a player stands in it)")
	assert_true(awake.has(wr.region_index(-440.0, 20.0)), "Ashmoor wakes (a player stands in it)")
	assert_false(
		awake.has(wr.region_index(0.0, -1400.0)), "Greyrise sleeps (no player anywhere near it)"
	)
	assert_eq(awake.size(), 2, "exactly the two occupied regions are awake")


func test_empty_world_wakes_nothing() -> void:
	# The idle-server floor: no players => every overworld zone sleeps.
	assert_eq(_SZ.awake_regions([], _regions(), 0.0).size(), 0, "no players => no awake zones")


# ---- (b) an open-world mob in an empty region is skipped (zero ticks) ------------------------
func test_open_world_mob_in_empty_region_is_skipped() -> void:
	var wr = _regions()
	# A lone Wold player: the Wold is awake, Ashmoor + Greyrise sleep.
	var awake: Dictionary = _SZ.awake_regions([Vector2(0.0, 0.0)], wr, 0.0)
	var wold_mob = _MD.new()
	wold_mob.position = Vector3(30.0, 20.0, 0.0)  # a Heartwold wolf
	var ashmoor_mob = _MD.new()
	ashmoor_mob.position = Vector3(-420.0, 29.0, 0.0)  # a Syndicate legbreaker
	assert_true(_SZ.is_mob_awake(wold_mob, awake, wr), "the Wold wolf ticks (a player is present)")
	assert_false(
		_SZ.is_mob_awake(ashmoor_mob, awake, wr), "the Ashmoor mob is skipped — its zone is empty"
	)


func test_ashmoor_mob_wakes_when_a_player_enters_ashmoor() -> void:
	var wr = _regions()
	var awake: Dictionary = _SZ.awake_regions([Vector2(-440.0, 20.0)], wr, 0.0)
	var ashmoor_mob = _MD.new()
	ashmoor_mob.position = Vector3(-420.0, 29.0, 0.0)
	assert_true(
		_SZ.is_mob_awake(ashmoor_mob, awake, wr), "the Ashmoor mob ticks once a player enters"
	)


# ---- (c) instance mobs are always awake -----------------------------------------------------
func test_instance_mobs_always_tick() -> void:
	var wr = _regions()
	var awake: Dictionary = {}  # no overworld zone awake
	var crypt_mob = _MD.new()
	crypt_mob.instance_id = 7  # a soft-instance (crypt party) mob
	crypt_mob.position = Vector3(420.0, 0.0, 0.0)
	assert_true(
		_SZ.is_mob_awake(crypt_mob, awake, wr),
		"an instance mob ticks regardless of the overworld sleeping-zone set"
	)


func test_null_region_table_degrades_to_always_tick() -> void:
	# A boot without regions.json must never freeze the world — degrade to the pre-T-594 behaviour.
	var mob = _MD.new()
	mob.position = Vector3(-420.0, 29.0, 0.0)
	assert_true(_SZ.is_mob_awake(mob, {}, null), "no region table => the mob still ticks")


# ---- (d) soak: players spread across N regions tick ONLY those regions' mobs -----------------
func test_soak_spread_ticks_only_occupied_regions() -> void:
	var wr = _regions()
	var mobs: Dictionary = _ML.load_spawn_table(MOBS_DIR)
	var by_region_id := _mobs_by_region_id()
	assert_true(by_region_id.get("wold", 0) > 0, "the Wold holds open-world mobs")
	assert_true(by_region_id.get("ashmoor", 0) > 0, "Ashmoor holds open-world mobs")

	# Lone Wold player: the mob-tick set must EXCLUDE every Ashmoor mob (the empty-zone budget).
	var awake_wold: Dictionary = _SZ.awake_regions([Vector2(0.0, 0.0)], wr, 0.0)
	var ticked_wold := 0
	for eid in mobs:
		if _SZ.is_mob_awake(mobs[eid], awake_wold, wr):
			ticked_wold += 1
	assert_eq(
		ticked_wold,
		by_region_id.get("wold", 0),
		"a lone Wold player ticks exactly the Wold mobs — every other zone sleeps"
	)

	# Players in BOTH populated regions: every open-world mob in those two zones ticks, Greyrise (no
	# mobs, no players) stays asleep and costs nothing.
	var awake_both: Dictionary = _SZ.awake_regions(
		[Vector2(0.0, 0.0), Vector2(-440.0, 20.0)], wr, 0.0
	)
	var ticked_both := 0
	for eid in mobs:
		if _SZ.is_mob_awake(mobs[eid], awake_both, wr):
			ticked_both += 1
	assert_eq(
		ticked_both,
		by_region_id.get("wold", 0) + by_region_id.get("ashmoor", 0),
		"two occupied regions tick exactly their combined mob set — no more"
	)
	assert_true(
		ticked_both > ticked_wold, "adding a second occupied region wakes more mobs, not all"
	)


# ---- (e) the optional origin wake margin (the P2 adjacent-border tunable) ---------------------
func test_wake_margin_wakes_a_nearby_region_origin() -> void:
	var wr = _regions()
	# A player at (0,-690) sits just on the WOLD side of the Wold/Greyrise nearest-origin seam
	# (690 m from the Wold origin vs 710 m from Greyrise's (0,-1400)), so membership alone leaves
	# Greyrise asleep. A 750 m origin margin reaches the Greyrise origin (710 m) and wakes it, while
	# still leaving Ashmoor asleep (its origin is 808 m away).
	var near_seam := [Vector2(0.0, -690.0)]
	var g_idx: int = wr.region_index(0.0, -1400.0)
	var a_idx: int = wr.region_index(-420.0, 0.0)
	assert_eq(
		wr.region_index(0.0, -690.0), wr.region_index(0.0, 0.0), "the seam point is in the Wold"
	)
	assert_false(
		_SZ.awake_regions(near_seam, wr, 0.0).has(g_idx), "margin 0 leaves the neighbour asleep"
	)
	var wide: Dictionary = _SZ.awake_regions(near_seam, wr, 750.0)
	assert_true(
		wide.has(g_idx), "a 750 m origin margin wakes the neighbouring zone (P2 border skirt)"
	)
	assert_false(wide.has(a_idx), "the margin does not over-wake the farther Ashmoor origin")


# ---- (f) per-active-region spawn loading -----------------------------------------------------
func test_filtered_loader_constructs_only_allowed_regions() -> void:
	var wr = _regions()
	var full: Dictionary = _ML.load_spawn_table(MOBS_DIR)
	var wold_idx: int = wr.region_index(0.0, 0.0)
	var only_wold: Dictionary = _ML.load_spawn_table_filtered(MOBS_DIR, wr, [wold_idx])
	assert_true(only_wold.size() > 0, "the Wold-only load constructs the Wold mobs")
	assert_true(only_wold.size() < full.size(), "it constructs FEWER mobs than the whole world")
	for eid in only_wold:
		assert_eq(
			wr.region_index(only_wold[eid].position.x, only_wold[eid].position.y),
			wold_idx,
			"every constructed mob lives in the allowed region"
		)


func test_empty_allowed_list_is_the_byte_identical_boot_load() -> void:
	# The P1 boot path: empty allow-list (or null table) loads EVERYTHING, same as load_spawn_table.
	var wr = _regions()
	var boot: Dictionary = _ML.load_spawn_table(MOBS_DIR)
	var filtered_all: Dictionary = _ML.load_spawn_table_filtered(MOBS_DIR, wr, [])
	assert_eq(
		filtered_all.size(), boot.size(), "empty allow-list loads the full table (boot parity)"
	)
	assert_eq(
		_ML.load_spawn_table_filtered(MOBS_DIR, null, [wr.region_index(0.0, 0.0)]).size(),
		boot.size(),
		"a null region table also loads everything (never freezes a boot)"
	)


func test_spawn_region_ids_reports_the_populated_zones() -> void:
	var wr = _regions()
	var ids: Array = _ML.spawn_region_ids(MOBS_DIR, wr)
	assert_true(ids.has(wr.region_index(0.0, 0.0)), "the Wold is reported as a populated zone")
	assert_true(ids.has(wr.region_index(-440.0, 20.0)), "Ashmoor is reported as a populated zone")
	assert_false(
		ids.has(wr.region_index(0.0, -1400.0)), "Greyrise has no spawns yet — not reported"
	)
