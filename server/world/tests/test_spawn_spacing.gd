# T-402: Ashmoor street-tier SPACING LINT. Pure JSON inspection — no OS time, no engine, no network.
#
# The live T-399 defect was accidental 2v1s: every legbreaker had a constable ~4.9m away, close
# enough to chain but presented as a separate mob. Under the T-402 level-relative aggro model reach
# is ~16-20m, so SPACING is what defines a pull. This lint ASSERTS the solo/duo/pack vocabulary
# (documented in spawns.json `_pull_vocabulary_doc`) over the ACTUAL spawn data, failing CLOSED so
# future authoring can't silently recreate the dead-zone trap. If this test goes red, the street
# tier has an ambiguous pull again — fix the positions, don't loosen the test.
#
# T-660 (#52, 2026-07-19): this lint used to be Ashmoor-only by construction — a Wold starter-zone
# regression (the Gray Wolf triple-aggro: (30,20)/(36,24)/(31,31) sat 11.0m/8.6m apart, BOTH inside
# the 8-30m dead zone) shipped invisibly because nothing here ever looked at the Wold band. The
# dead-zone/vocabulary checks now also run over `_WOLD_FILES`.
#
# T-617 (2026-07-19): elite ISOLATION oracle (world-wide) — every spawn flagged elite/rare gets a
# trash-free escape buffer: no non-elite spawn point inside minf(AGGRO_MAX, the elite's own
# leash_radius). T-402's pack/solo grammar covers trash-vs-trash chaining; an elite carries far
# higher per-hit damage than the trash beside it, so an add joining an elite fight (or a player
# fleeing the elite through a trash camp) turns a survivable "smart no" into an unsurvivable pile
# (soak-12's full-HP L7 death at Grexrok). A deliberately-authored elite-led PACK (the T-402
# PACK-D torpedo core) is exempt BY NAME below — one honest pull, presented as standing together.
# kobold_miner joined `_WOLD_FILES` in the same change (T-660 deferred it until this oracle).

extends GutTest

const _SC = preload("res://scripts/server_config.gd")
const _SPAWNS_PATH := "res://data/mobs/spawns.json"

# The Ashmoor street tier (the T-349/T-350 Syndicate family). These are the mob files whose spawns
# form the pull grammar; the meadow/crypt mobs live under different rules and are out of scope.
const _ASHMOOR_FILES := [
	"syndicate_legbreaker.json",
	"constable_take.json",
	"seance_warden.json",
	"syndicate_gunsel.json",
	"syndicate_torpedo.json",
	# T-411: the rare 'champion' rides the same street-tier spacing grammar — a SOLO pull that must
	# stay >= 30m from every other spawn (it is authored well SW of the tier). Including it here
	# fails CLOSED if a future author drags the rare into the 8-30m dead zone.
	"rare_ashmoor_kingpin.json",
]

# T-660 (#52): the Wold starter-zone pull grammar. T-617 added kobold_miner once the elite-buffer
# respace moved its camp out of the Grexrok adjacency.
const _WOLD_FILES := ["wolf.json", "kobold_miner.json"]

# T-617: elites authored as the core of a deliberate same-pack pull (T-402 PACK-D: the torpedo's
# gunsel/warden escort stands <=8m around it — one honest pack pull). Exempt BY NAME so any new
# elite fails CLOSED until an author consciously declares its pack here.
const _ELITE_PACK_CORES := ["syndicate_torpedo.json"]

# A cluster's members read as "standing together" and are pulled as one honest group.
const _LINK_RADIUS := 8.0
# The ASHMOOR_ARRIVAL plaza (instance_service.ASHMOOR_ARRIVAL). A fresh arrival — possibly UNDER the
# mob level, so its aggro reach grows toward the cap — must not be inside any mob's reach on step-in.
const _ARRIVAL := Vector2(-420.0, -5.0)


# Separation beyond which one mob can't be dragged into another's pull: 1.5x the worst-case reach.
func _solo_sep() -> float:
	return 1.5 * _SC.AGGRO_MAX


func _arrival_clearance() -> float:
	return _SC.AGGRO_MAX + 4.0  # a small margin past the worst-case aggro reach


# T-660: generalized out of the old _ashmoor_points body so the Wold pack can reuse the same read.
func _points_for_files(files: Array) -> Array:
	var f := FileAccess.open(_SPAWNS_PATH, FileAccess.READ)
	assert_not_null(f, "spawns.json must open")
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	var wanted := {}
	for name in files:
		wanted[name] = true
	var pts: Array = []
	for entry in parsed.get("spawns", []):
		if wanted.has(str(entry.get("mob_file", ""))):
			for pos in entry.get("positions", []):
				pts.append(Vector2(float(pos[0]), float(pos[1])))
	return pts


func _ashmoor_points() -> Array:
	return _points_for_files(_ASHMOOR_FILES)


func _wold_points() -> Array:
	return _points_for_files(_WOLD_FILES)


# Shared by both the Ashmoor and Wold pair-spacing tests: every pair in `pts` must read as one
# cluster (<=8m) or a clearly separate pull (>=`sep`) — never the T-399/#52 dead-zone chain.
func _assert_pairs_linked_or_separate(pts: Array, sep: float) -> void:
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			var d: float = pts[i].distance_to(pts[j])
			var ok: bool = d <= _LINK_RADIUS or d >= sep
			assert_true(
				ok,
				(
					(
						"pair %s/%s is %.1fm apart — in the DEAD ZONE (%.0f-%.0fm): an accidental chain "
						% [str(pts[i]), str(pts[j]), d, _LINK_RADIUS, sep]
					)
					+ "that reads as a separate pull (the T-399 2v1 trap). Cluster it (<=8m) or split it (>=30m)."
				)
			)


# --- T-618: no hostile spawn may sit inside a service hub's own worst-case reach --------------
# #71's live-proven trap: the arrival-plaza clearance (test_no_spawn_inside_arrival_reach above)
# only covers the plaza — it says nothing about the High Street SERVICE ROW itself (the
# constabulary/quest-giver + the walk_in shopfronts), which is the actual destination players are
# sent to. Mirrors test_trainer_spawn_safety.gd's idiom exactly: the keep-out distance is each
# mob's OWN leash_radius (mob_aggro.gd clamps effective reach to minf(AGGRO_MAX, leash_radius), so
# leash_radius IS the mob's true worst-case pull from its spawn, regardless of the visitor's level).
func _ashmoor_entries() -> Array:
	var f := FileAccess.open(_SPAWNS_PATH, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	var wanted := {}
	for name in _ASHMOOR_FILES:
		wanted[name] = true
	var out: Array = []  # [Vector2 pos, float leash, String mob_file]
	for entry in parsed.get("spawns", []):
		var mob_file := str(entry.get("mob_file", ""))
		if not wanted.has(mob_file):
			continue
		var mf := FileAccess.open("res://data/mobs/%s" % mob_file, FileAccess.READ)
		var mob = JSON.parse_string(mf.get_as_text()) if mf != null else {}
		if mf != null:
			mf.close()
		var leash := (
			float((mob as Dictionary).get("leash_radius", 15.0)) if mob is Dictionary else 15.0
		)
		for pos in entry.get("positions", []):
			out.append([Vector2(float(pos[0]), float(pos[1])), leash, mob_file])
	return out


# Service hubs: any Ashmoor NPC that gives a quest or runs a service (talk position), plus every
# `walk_in: true` building anchor in the region's own high_street data — the "destination" set the
# T-618 ticket's own table measured against (Desk Sergeant Coyle, the constabulary, the Grey Gull
# terrace fronts, the warehouse/rowhouses). Server-authoritative, not the client's visual props.
func _ashmoor_service_hubs() -> Array:
	var out: Array = []  # [Vector2 pos, String label]
	var npc_f := FileAccess.open("res://data/npcs/npcs.json", FileAccess.READ)
	assert_not_null(npc_f, "npcs.json must open")
	var npc_doc = JSON.parse_string(npc_f.get_as_text())
	npc_f.close()
	for npc: Dictionary in (npc_doc as Dictionary).get("npcs", []):
		var id := str(npc.get("id", ""))
		if not id.begins_with("npc_ashmoor_"):
			continue
		var is_service := (
			not (npc.get("gives_quests", []) as Array).is_empty()
			or bool(npc.get("trainer", false))
			or str(npc.get("service", "")) != ""
		)
		if is_service:
			out.append([Vector2(float(npc.get("x", 0.0)), float(npc.get("y", 0.0))), id])
	var region_f := FileAccess.open("res://data/regions/ashmoor.json", FileAccess.READ)
	assert_not_null(region_f, "regions/ashmoor.json must open")
	var region_doc = JSON.parse_string(region_f.get_as_text())
	region_f.close()
	var buildings: Array = (region_doc as Dictionary).get("high_street", {}).get("buildings", [])
	for b: Dictionary in buildings:
		if not bool(b.get("walk_in", false)):
			continue
		var a: Array = b.get("anchor", [0.0, 0.0])
		out.append([Vector2(float(a[0]), float(a[1])), str(b.get("model", "building"))])
	return out


func test_no_hostile_spawn_within_its_own_leash_of_a_service_hub() -> void:
	var hubs := _ashmoor_service_hubs()
	assert_gt(hubs.size(), 0, "at least one Ashmoor service hub is defined")
	var entries := _ashmoor_entries()
	assert_gt(entries.size(), 0, "at least one Ashmoor spawn is defined")
	for e: Array in entries:
		var pos: Vector2 = e[0]
		var leash: float = e[1]
		var mob_file: String = e[2]
		for hub: Array in hubs:
			var hub_pos: Vector2 = hub[0]
			var hub_label: String = hub[1]
			var dist := pos.distance_to(hub_pos)
			assert_true(
				dist >= leash,
				(
					(
						"%s spawn %s is %.1fm from service hub %s (need >= its own leash_radius "
						% [mob_file, pos, dist, hub_label]
					)
					+ (
						"%.1fm; a player heading to that destination could be aggroed/killed en route)"
						% leash
					)
				)
			)


# --- the core invariant: no ambiguous pull ---------------------------------------------------
func test_every_pair_is_linked_or_clearly_separate() -> void:
	var pts := _ashmoor_points()
	assert_gt(pts.size(), 3, "the street tier has several spawns to space")
	_assert_pairs_linked_or_separate(pts, _solo_sep())


# T-660 (#52): the Wold starter-zone counterpart — the Gray Wolf triple-aggro regression. Fails
# CLOSED so a future re-authoring of the starter pack can't silently recreate the dead-zone chain.
func test_wold_pack_is_linked_or_clearly_separate() -> void:
	var pts := _wold_points()
	assert_gt(pts.size(), 1, "the Wold starter pack has multiple spawns to space")
	_assert_pairs_linked_or_separate(pts, _solo_sep())


# T-660: shared by both vocabulary tests below — returns [solo_count, clustered_count] over `pts`.
func _vocabulary_counts(pts: Array, sep: float) -> Array:
	var solos := 0
	var clustered := 0
	for i in range(pts.size()):
		var nearest := INF
		var has_link_partner := false
		for j in range(pts.size()):
			if i == j:
				continue
			var d: float = pts[i].distance_to(pts[j])
			nearest = minf(nearest, d)
			if d <= _LINK_RADIUS:
				has_link_partner = true
		if nearest >= sep:
			solos += 1
		if has_link_partner:
			clustered += 1
	return [solos, clustered]


# T-660: the Wold pack must offer the SAME solo/duo vocabulary the Ashmoor tier does, not just
# avoid the dead zone — a starter zone that's all-duo or all-solo is a different (untested) design.
func test_wold_vocabulary_has_a_solo_and_a_cluster() -> void:
	var counts := _vocabulary_counts(_wold_points(), _solo_sep())
	assert_gt(counts[0], 0, "the Wold pack offers at least one SOLO pull (a winnable 1v1)")
	assert_gt(counts[1], 0, "the Wold pack offers at least one DUO (a deliberate multi-pull)")


# --- the vocabulary actually exists: at least one solo AND at least one cluster ---------------
func test_vocabulary_has_a_solo_and_a_cluster() -> void:
	var counts := _vocabulary_counts(_ashmoor_points(), _solo_sep())
	assert_gt(
		counts[0],
		0,
		"the tier offers at least one SOLO pull (a winnable 1v1, per the T-399 lesson)"
	)
	assert_gt(counts[1], 0, "the tier offers at least one DUO/PACK (a deliberate multi-pull)")


# --- T-617: elite isolation — a trash-free escape buffer around every elite/rare spawn --------
# World-wide (every entry in spawns.json, not a zone allowlist): for each spawn point of a mob
# flagged `elite` or `rare`, no NON-elite spawn point may sit inside minf(AGGRO_MAX, the elite's
# own leash_radius) — the elite's true worst-case pull from its spawn (mob_aggro.gd clamps
# effective reach to that). Additive to the pack/solo grammar above: trash-vs-trash chaining is
# T-402's rule; this one guarantees a player who correctly reads an elite as too strong can ALWAYS
# disengage without dragging (or fleeing through) an adjacent trash camp — the "smart no" stays a
# skill expression instead of a Kahneman-unfair death (game-direction.md §2, soak-12's repro).
func _all_spawn_entries() -> Array:
	var f := FileAccess.open(_SPAWNS_PATH, FileAccess.READ)
	assert_not_null(f, "spawns.json must open")
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	var out: Array = []  # [Vector2 pos, float leash, bool elite_or_rare, String mob_file]
	for entry in parsed.get("spawns", []):
		var mob_file := str(entry.get("mob_file", ""))
		var mf := FileAccess.open("res://data/mobs/%s" % mob_file, FileAccess.READ)
		var mob = JSON.parse_string(mf.get_as_text()) if mf != null else {}
		if mf != null:
			mf.close()
		var mob_dict: Dictionary = mob if mob is Dictionary else {}
		var leash := float(mob_dict.get("leash_radius", 15.0))
		var flagged := bool(mob_dict.get("elite", false)) or bool(mob_dict.get("rare", false))
		for pos in entry.get("positions", []):
			out.append([Vector2(float(pos[0]), float(pos[1])), leash, flagged, mob_file])
	return out


func test_every_elite_spawn_has_a_trash_free_escape_buffer() -> void:
	var entries := _all_spawn_entries()
	var elites := entries.filter(func(e): return e[2] and not _ELITE_PACK_CORES.has(e[3]))
	assert_gt(elites.size(), 2, "the bounty elites (Greymaw/Grexrok/Elderthorn) are in the table")
	for elite: Array in elites:
		var exclusion: float = minf(_SC.AGGRO_MAX, elite[1])
		for other: Array in entries:
			if other[2]:  # elite-vs-elite spacing is not this rule's concern
				continue
			var d: float = (elite[0] as Vector2).distance_to(other[0])
			assert_true(
				d >= exclusion,
				(
					(
						"%s spawn %s has non-elite %s only %.1fm away (need >= %.1fm, its "
						% [elite[3], str(elite[0]), other[3], d, exclusion]
					)
					+ (
						"aggro-clamped reach): an add joining the elite fight — or a player "
						+ "fleeing through the camp — compounds a fair elite death into an "
						+ "unavoidable one (T-617). Move the trash or declare a deliberate "
						+ "pack core in _ELITE_PACK_CORES."
					)
				)
			)


# --- the arrival plaza stays outside every mob's reach ---------------------------------------
func test_no_spawn_inside_arrival_reach() -> void:
	var clearance := _arrival_clearance()
	for p in _ashmoor_points():
		assert_gt(
			p.distance_to(_ARRIVAL),
			clearance,
			(
				(
					"spawn %s is only %.1fm from the arrival plaza — inside worst-case aggro; a fresh "
					% [str(p), p.distance_to(_ARRIVAL)]
				)
				+ "arrival would be swarmed on step-in (T-330 vestibule lesson)."
			)
		)
