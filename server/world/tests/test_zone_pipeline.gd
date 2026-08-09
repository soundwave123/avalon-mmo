extends GutTest

# T-595: the per-zone content-pipeline integrity oracle. For EVERY zone sheet under data/zones/, it
# re-runs the shipped safety/placement/loot/node/quest invariants scoped to that zone's emitted
# content (the data tools/zonegen/zonegen.py produced from the sheet). It fails CLOSED, so a future
# `zonegen <zone>` run that drifts a camp onto a hub, strands a node off-region, breaks the gather
# pool shape, or names an unreachable quest item goes red HERE — the pipeline can't silently ship a
# broken zone. This is the headless half of the pipeline's "one zone in, one zone out" contract;
# the dressing half lives in client/tests/test_zone_dressing.gd.
#
# It re-expresses the world-wide oracles (spawn_safety/spacing/trainer, region_local_bounds,
# loot_bands, discovery_nodes) PER ZONE off the sheet — which makes each future zone a production
# run with its own green gate.

const _WR = preload("res://scripts/world_regions.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")
const _CQ = preload("res://scripts/content/content_query.gd")  # T-622: elite-tag resolution
const _DISC = preload("res://scripts/discovery_nodes.gd")
const _SC = preload("res://scripts/server_config.gd")

const LOCAL_LIMIT := 4000.0  # the ±4 km single-precision rule (test_region_local_bounds)
const SAFE_MOB_LEVEL := 3
const HUB_CLEARANCE := 30.0  # T-515
const LINK_RADIUS := 8.0  # T-402 cluster
const NODE_KINDS := ["herb", "ore", "timber", "fibre", "fishing"]

# T-622 quest-density budget constants (WoW Loremaster: 40-60/zone, ~10% elite, 2-3 breadcrumbs).
const BUDGET_MIN := 40
const BUDGET_MAX := 60
const BAND_FLOOR := 8  # T-595 chain-sizing floor per content-bearing band
const ELITE_RATIO_MIN := 0.06
const ELITE_RATIO_MAX := 0.16
const BREADCRUMB_XP_CAP := 150  # a breadcrumb is a small NAVIGATION payout, not a leveling shortcut
const HUB_MATCH_RADIUS := 20.0  # a breadcrumb reach must land on a real neighbour flight node

# T-627 solo-path coverage: the L10-20 band this ticket owns (each level in [10, 20) is checked).
const HIGHLAND_LO := 10
const HIGHLAND_HI := 20
const _CRYPT_PORCH := Vector2(14.0, -12.5)  # the Hollowed Crypt door — spine must not route here


func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _zone_sheets() -> Array:
	# Every data/zones/*.json sheet — the per-zone loop the whole pipeline is built to repeat.
	var out: Array = []
	var dir := DirAccess.open("res://data/zones")
	if dir == null:
		return out
	for name in dir.get_files():
		if name.ends_with(".json"):
			var sheet: Variant = _load_json("res://data/zones/%s" % name)
			if sheet is Dictionary:
				out.append(sheet)
	return out


func _solo_sep() -> float:
	return 1.5 * _SC.AGGRO_MAX


func _mob(mob_file: String) -> Dictionary:
	var d: Variant = _load_json("res://data/mobs/%s" % mob_file)
	return d if d is Dictionary else {}


# ---- fixtures shared by the per-zone assertions --------------------------------------------
func _hubs() -> Array:
	var doc: Variant = _load_json("res://data/regions/spawn_points.json")
	var out: Array = []
	for h in (doc as Dictionary).get("hubs", []):
		out.append(Vector2(float(h[0]), float(h[1])))
	return out


func _service_npcs() -> Array:
	var doc: Variant = _load_json("res://data/npcs/npcs.json")
	var out: Array = []
	for n in (doc as Dictionary).get("npcs", []):
		var is_service: bool = (
			bool(n.get("trainer", false))
			or str(n.get("service", "")) != ""
			or not (n.get("gives_quests", []) as Array).is_empty()
		)
		if is_service:
			out.append(Vector2(float(n.get("x", 0.0)), float(n.get("y", 0.0))))
	return out


func _elite_buffers() -> Array:
	# [Vector2 pos, float minf(AGGRO_MAX, leash)] for every elite/rare spawn — the T-617 buffer.
	var doc: Variant = _load_json("res://data/mobs/spawns.json")
	var out: Array = []
	for e in (doc as Dictionary).get("spawns", []):
		var mob := _mob(str(e.get("mob_file", "")))
		if not (bool(mob.get("elite", false)) or bool(mob.get("rare", false))):
			continue
		var buf := minf(_SC.AGGRO_MAX, float(mob.get("leash_radius", 15.0)))
		for pos in e.get("positions", []):
			out.append([Vector2(float(pos[0]), float(pos[1])), buf])
	return out


func _zone_spawn_entries(zone_id: String) -> Array:
	var doc: Variant = _load_json("res://data/mobs/spawns.json")
	var out: Array = []
	for e in (doc as Dictionary).get("spawns", []):
		if str(e.get("_zone", "")) == zone_id:
			out.append(e)
	return out


# =============================================================================================
# 1. SPAWN SAFETY — every zone camp respects hub / trainer / elite / dead-zone oracles.
func test_zone_spawns_pass_every_safety_oracle() -> void:
	var wr = _WR.load_default()
	var hubs := _hubs()
	var npcs := _service_npcs()
	var elites := _elite_buffers()
	for sheet in _zone_sheets():
		var zone_id := str(sheet["id"])
		var region_id := str(sheet["region_id"])
		var entries := _zone_spawn_entries(zone_id)
		# The sheet declares camps; the emitted data must contain them (the pipeline actually ran).
		var declared: int = (sheet.get("spawns", {}) as Dictionary).get("camps", []).size()
		if declared == 0:
			continue
		assert_gt(
			entries.size(),
			0,
			"zone '%s' declares camps but none were emitted (run zonegen)" % zone_id
		)
		var wold_pts: Array = []  # this zone's wolf/kobold points, for the dead-zone check
		for e in entries:
			var mob := _mob(str(e.get("mob_file", "")))
			var leash := float(mob.get("leash_radius", 15.0))
			var level := int(mob.get("level", 1))
			# T-617's rule is about NON-elite trash near an elite; an elite (e.g. a T-627 roaming
			# named elite spawned as zone content) is not "inside" its own/a peer's escape buffer.
			var is_flagged: bool = bool(mob.get("elite", false)) or bool(mob.get("rare", false))
			var is_wold_family: bool = (
				str(e.get("mob_file", "")) in ["wolf.json", "kobold_miner.json"]
			)
			for pos in e.get("positions", []):
				var p := Vector2(float(pos[0]), float(pos[1]))
				assert_eq(
					wr.region_id_at(p.x, p.y),
					region_id,
					(
						"zone '%s' spawn %s routes to region %s, not %s"
						% [zone_id, p, wr.region_id_at(p.x, p.y), region_id]
					)
				)
				assert_lte(
					p.distance_to(wr.origin_at(p.x, p.y)),
					LOCAL_LIMIT,
					"zone '%s' spawn %s is > 4 km from its region origin" % [zone_id, p]
				)
				if level > SAFE_MOB_LEVEL:
					for h in hubs:
						assert_gte(
							p.distance_to(h),
							HUB_CLEARANCE,
							(
								"zone '%s' L%d spawn %s within %.0f m of hub %s (T-515)"
								% [zone_id, level, p, HUB_CLEARANCE, h]
							)
						)
				for npc in npcs:
					assert_gte(
						p.distance_to(npc),
						leash,
						(
							"zone '%s' spawn %s within its own leash %.1f of service NPC %s (T-585)"
							% [zone_id, p, leash, npc]
						)
					)
				if not is_flagged:
					for eb in elites:
						assert_gte(
							p.distance_to(eb[0]),
							eb[1],
							(
								"zone '%s' spawn %s inside an elite escape buffer at %s (T-617)"
								% [zone_id, p, eb[0]]
							)
						)
				if is_wold_family:
					wold_pts.append(p)
		# T-402/T-660 dead zone among this zone's wolf/kobold camps: <=8 m (cluster) or >=30 m (separate).
		var sep := _solo_sep()
		for i in range(wold_pts.size()):
			for j in range(i + 1, wold_pts.size()):
				var d: float = wold_pts[i].distance_to(wold_pts[j])
				assert_true(
					d <= LINK_RADIUS or d >= sep,
					(
						"zone '%s' wolf/kobold pair %s/%s is %.1f m — the T-399 dead zone"
						% [zone_id, wold_pts[i], wold_pts[j], d]
					)
				)


# =============================================================================================
# 2. GATHER POOL — the WoW pool shape (min always-up + bonus variable-ratio + exactly one rare).
func test_zone_gather_pool_shape_is_valid() -> void:
	var wr = _WR.load_default()
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var items: Dictionary = loaded["items"]
	var nodes_doc: Variant = _load_json("res://data/gather/nodes.json")
	for sheet in _zone_sheets():
		var pool: Dictionary = sheet.get("gather_pool", {})
		if pool.is_empty():
			continue
		var prefix := str(pool["id_prefix"])
		var region_id := str(sheet["region_id"])
		var mins := 0
		var bonuses := 0
		var rares := 0
		var seen := {}
		for node in (nodes_doc as Dictionary).get("nodes", []):
			var nid := str(node.get("id", ""))
			if not nid.begins_with(prefix):
				continue
			assert_false(seen.has(nid), "duplicate pool node id %s" % nid)
			seen[nid] = true
			assert_true(
				NODE_KINDS.has(str(node.get("kind", ""))), "%s has a valid gather kind" % nid
			)
			assert_true(items.has(str(node.get("item_id", ""))), "%s yields a registry item" % nid)
			assert_gt(int(node.get("respawn_ticks", 0)), 0, "%s has a real respawn timer" % nid)
			var p := Vector2(float(node.get("x", 0.0)), float(node.get("y", 0.0)))
			assert_eq(
				wr.region_id_at(p.x, p.y), region_id, "%s sits in region %s" % [nid, region_id]
			)
			assert_lte(
				p.distance_to(wr.origin_at(p.x, p.y)), LOCAL_LIMIT, "%s within 4 km of origin" % nid
			)
			var chance := float(node.get("spawn_chance", 1.0))
			var respawn := int(node.get("respawn_ticks", 0))
			if respawn >= 3600 and chance < 0.5:
				rares += 1
			elif chance >= 1.0:
				mins += 1
			else:
				bonuses += 1
		assert_gte(mins, pool.get("min_nodes", []).size(), "the min (always-up) set is present")
		assert_gt(
			bonuses, 0, "the bonus (variable-ratio) set is present — not every node up at once"
		)
		assert_eq(
			rares, 1, "exactly ONE 1-per-zone rare node (the economy chase, Black-Lotus analog)"
		)


# =============================================================================================
# 3. LOOT — the zone's spawned mob families keep banded, reachable loot (no chance:1.0 trap).
func test_zone_mob_loot_stays_banded_and_reachable() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var quests: Dictionary = loaded["quests"]
	var quest_items := {}
	for qid in quests:
		for obj in quests[qid].objectives:
			if str(obj.get("type", "")) == "collect":
				quest_items[str(obj.get("target", ""))] = true
	for sheet in _zone_sheets():
		var families := {}
		for camp in (sheet.get("spawns", {}) as Dictionary).get("camps", []):
			families[str(camp.get("family", "")) + ".json"] = true
		for mob_file in families:
			var mob := _mob(mob_file)
			var loot: Array = mob.get("loot", [])
			if int(mob.get("difficulty", 1)) >= 5:
				continue  # elites carry signature identity loot, out of the band retrofit
			assert_gt(loot.size(), 0, "%s has a loot table" % mob_file)
			var has_variance := false
			for entry in loot:
				var chance := float(entry.get("chance", 1.0))
				assert_true(chance > 0.0 and chance <= 1.0, "%s loot chance in (0,1]" % mob_file)
				if chance < 1.0:
					has_variance = true
				# a quest-collected drop must stay reachable (>= the 0.35 grind-wall floor).
				if quest_items.has(str(entry.get("item_id", ""))):
					assert_gte(
						chance,
						0.35,
						(
							"%s: quest item %s must stay reachable"
							% [mob_file, entry.get("item_id", "")]
						)
					)
			assert_true(
				has_variance,
				"%s must have a sub-1.0 drop (no fixed-ratio determinism trap)" % mob_file
			)


# =============================================================================================
# 4. DISCOVERY POIs — valid, in-region, local, zone-tagged.
func test_zone_discovery_pois_are_valid_and_local() -> void:
	var wr = _WR.load_default()
	var loaded: Dictionary = _DISC.load_file("res://data/discovery_nodes.json")
	assert_eq(
		str(loaded["errors"]), "[]", "the discovery file validates clean with the zone POIs added"
	)
	for sheet in _zone_sheets():
		var declared: Array = sheet.get("discovery_pois", [])
		if declared.is_empty():
			continue
		var zone_id := str(sheet["id"])
		var region_id := str(sheet["region_id"])
		var found := 0
		for node in loaded["nodes"]:
			if str(node.get("zone", "")) != zone_id:
				continue
			found += 1
			var p := Vector2(float(node.get("x", 0.0)), float(node.get("y", 0.0)))
			assert_eq(
				wr.region_id_at(p.x, p.y),
				region_id,
				"POI %s sits in region %s" % [node.get("id", ""), region_id]
			)
			assert_lte(
				p.distance_to(wr.origin_at(p.x, p.y)),
				LOCAL_LIMIT,
				"POI %s within 4 km of origin" % node.get("id", "")
			)
		assert_eq(
			found,
			declared.size(),
			"zone '%s' emitted all %d declared POIs" % [zone_id, declared.size()]
		)


# =============================================================================================
# 5. QUEST CHAIN — the zone's declared chain loads clean, is reachable, and grants XP.
func test_zone_quest_chain_is_wired_reachable_and_pays_xp() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	assert_eq(str(loaded["errors"]), "[]", "all content (with the zone additions) loads clean")
	var quests: Dictionary = loaded["quests"]
	for sheet in _zone_sheets():
		var chain: Dictionary = sheet.get("quest_chain", {})
		if chain.is_empty():
			continue
		var zone_id := str(sheet["id"])
		var ids: Array = []
		ids.append_array(chain.get("hub_quests", []))
		ids.append_array(chain.get("bridge_quests", []))
		assert_gte(ids.size(), 8, "zone '%s' fields an 8-15+ quest chain" % zone_id)
		var band_levels := {}
		for qid in ids:
			assert_true(quests.has(str(qid)), "zone '%s' quest %s loaded" % [zone_id, qid])
			if not quests.has(str(qid)):
				continue
			var q = quests[str(qid)]
			assert_gt(int(q.rewards.get("xp", 0)), 0, "quest %s pays XP" % qid)
			var prereq := str(q.prerequisite_quest)
			if prereq != "":
				assert_true(quests.has(prereq), "quest %s prereq %s exists" % [qid, prereq])
			band_levels[int(q.min_level)] = true
		# Band coverage: the chain must span more than one level tier (a real leveling spine).
		assert_gt(band_levels.size(), 3, "zone '%s' chain spans several level tiers" % zone_id)


# =============================================================================================
# 6. SHEET WELL-FORMEDNESS — wings name real biomes; the sheet the pipeline consumes is sane.
func test_zone_sheet_is_well_formed() -> void:
	var wr = _WR.load_default()
	for sheet in _zone_sheets():
		var zone_id := str(sheet["id"])
		var region_id := str(sheet["region_id"])
		# The zone's region must exist in the WorldRegions table (T-590 seam).
		var region_known := false
		for i in wr.region_count():
			if wr.region_id_of(i) == region_id:
				region_known = true
		assert_true(region_known, "zone '%s' names a real region '%s'" % [zone_id, region_id])
		var kits: Dictionary = sheet.get("biome_kits", {})
		for w in sheet.get("wings", []):
			assert_true(
				kits.has(str(w.get("biome", ""))),
				"wing %s biome '%s' has a kit" % [w.get("id", ""), w.get("biome", "")]
			)
			var band: Array = w.get("band", [])
			assert_eq(band.size(), 2, "wing %s declares a [min,max] band" % w.get("id", ""))


# =============================================================================================
# T-622 QUEST-DENSITY BUDGET ORACLE. For every zone that carries a FULL quest ledger (a
# quest_chain with a `breadcrumbs` category — the T-622 production contract), assert the WoW
# Loremaster budget: 40-60 quests/zone, ~10% group/elite (Elite-tagged + resolving in the offer
# panel/tracker), 2-3 breadcrumbs pointing at real neighbour hubs, and a per-band content floor on
# the L1-10 arc this ticket owns. Fails CLOSED so a zonegen/content run that drifts a zone under
# density, over 60, off-ratio, or points a breadcrumb at nothing goes red here.


# Union every quest-id list in the sheet's quest_chain (day_one/bounties/hub/breadcrumbs/bridge),
# ignoring the _doc string — the full set of quests attributed to this zone.
func _zone_quest_ids(sheet: Dictionary) -> Array:
	var ids := {}
	var chain: Dictionary = sheet.get("quest_chain", {})
	for key in chain:
		var v = chain[key]
		if v is Array:
			for qid in v:
				if qid is String:
					ids[str(qid)] = true
	return ids.keys()


func _has_full_ledger(sheet: Dictionary) -> bool:
	# Only zones that declare the T-622 production ledger (a breadcrumbs category) are budget-gated;
	# a bare proof sheet is exempt. Every SHIPPING zone must carry the full ledger.
	return (sheet.get("quest_chain", {}) as Dictionary).has("breadcrumbs")


func _flight_nodes() -> Array:
	var doc: Variant = _load_json("res://data/travel/flight_nodes.json")
	var out: Array = []
	for n in (doc as Dictionary).get("nodes", []):
		var c: Array = n.get("coords", [0, 0])
		out.append({"id": str(n.get("id", "")), "pos": Vector2(float(c[0]), float(c[1]))})
	return out


# ---- 7. DENSITY BUDGET: 40-60 quests/zone + a per-band floor on the L1-10 arc ---------------
func test_zone_quest_density_hits_budget() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var quests: Dictionary = loaded["quests"]
	for sheet in _zone_sheets():
		if not _has_full_ledger(sheet):
			continue
		var zone_id := str(sheet["id"])
		var ids := _zone_quest_ids(sheet)
		# Every enumerated quest must actually load (no ghost ids in the ledger).
		for qid in ids:
			assert_true(quests.has(qid), "zone '%s' ledger names a real quest %s" % [zone_id, qid])
		assert_between(
			ids.size(),
			BUDGET_MIN,
			BUDGET_MAX,
			"zone '%s' has %d quests — WoW Loremaster budget is 40-60/zone" % [zone_id, ids.size()]
		)
		# Per-band floor on the content-bearing L1-10 arc (the bands THIS ticket owns). Starter
		# density runs hot by design (quest-xp-reference §4: leveling zones sit at the high end), so
		# the 40-60 zone total is the ceiling — bands are floored, not capped. L10-20 open-world solo
		# density is completed by T-627, so those bands are not floored here.
		var band_counts := {1: 0, 6: 0}  # 5-level buckets keyed by their low edge
		for qid in ids:
			if not quests.has(qid):
				continue
			var ml := int(quests[qid].min_level)
			if ml >= 1 and ml <= 5:
				band_counts[1] += 1
			elif ml >= 6 and ml <= 10:
				band_counts[6] += 1
		assert_gte(
			band_counts[1],
			BAND_FLOOR,
			"zone '%s' L1-5 band has >= %d quests" % [zone_id, BAND_FLOOR]
		)
		assert_gte(
			band_counts[6],
			BAND_FLOOR,
			"zone '%s' L6-10 band has >= %d quests" % [zone_id, BAND_FLOOR]
		)


# ---- 8. GROUP/ELITE: ~10% ratio + the Elite tag resolves in the offer preview AND the log -----
func test_zone_elite_ratio_and_tag_resolution() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var quests: Dictionary = loaded["quests"]
	for sheet in _zone_sheets():
		if not _has_full_ledger(sheet):
			continue
		var zone_id := str(sheet["id"])
		var ids := _zone_quest_ids(sheet)
		var elite_ids: Array = []
		for qid in ids:
			if quests.has(qid) and int(quests[qid].recommended_players) > 1:
				elite_ids.append(qid)
		assert_gt(elite_ids.size(), 0, "zone '%s' has group/elite quests" % zone_id)
		var ratio := float(elite_ids.size()) / float(ids.size())
		assert_between(
			ratio,
			ELITE_RATIO_MIN,
			ELITE_RATIO_MAX,
			"zone '%s' elite ratio %.2f — budget is ~10%%" % [zone_id, ratio]
		)
		# The tag must actually resolve on BOTH surfaces the player reads: the offer card and the
		# active-quest log/tracker view-model. Server owns the flag (recommended_players > 1).
		var sample := str(elite_ids[0])
		var offers := _CQ.talk_previews([sample], [], quests)
		assert_true(
			bool(offers[0].get("elite", false)), "elite quest %s tags in the offer panel" % sample
		)
		var log := _CQ.enrich_quest_log(
			[{"quest_id": sample, "state": "active", "progress": []}], quests, 8
		)
		assert_true(
			bool(log[0].get("elite", false)), "elite quest %s tags in the tracker/log" % sample
		)
		# And a plain solo quest must NOT carry the badge (no false positives).
		var solo := ""
		for qid in ids:
			if quests.has(qid) and int(quests[qid].recommended_players) <= 1:
				solo = str(qid)
				break
		if solo != "":
			var solo_offers := _CQ.talk_previews([solo], [], quests)
			assert_false(
				bool(solo_offers[0].get("elite", false)), "solo quest %s is not Elite" % solo
			)


# ---- 9. BREADCRUMBS: 2-3 pure-navigation hand-offs pointing at real neighbour hubs -----------
func test_zone_breadcrumbs_point_at_real_neighbour_hubs() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var quests: Dictionary = loaded["quests"]
	var nodes := _flight_nodes()
	for sheet in _zone_sheets():
		if not _has_full_ledger(sheet):
			continue
		var zone_id := str(sheet["id"])
		var crumbs: Array = (sheet.get("quest_chain", {}) as Dictionary).get("breadcrumbs", [])
		assert_between(crumbs.size(), 2, 3, "zone '%s' fields 2-3 breadcrumbs" % zone_id)
		for qid in crumbs:
			assert_true(quests.has(str(qid)), "breadcrumb %s loads" % qid)
			if not quests.has(str(qid)):
				continue
			var q = quests[str(qid)]
			# Pure navigation: at least one reach objective, and no combat/collect grind.
			var reach_pt := Vector2.INF
			var has_reach := false
			for obj: Dictionary in q.objectives:
				var t := str(obj.get("type", ""))
				assert_eq(t, "reach", "breadcrumb %s is pure navigation (reach only)" % qid)
				if t == "reach":
					has_reach = true
					reach_pt = Vector2(float(obj.get("x", 0.0)), float(obj.get("y", 0.0)))
			assert_true(has_reach, "breadcrumb %s has a reach objective" % qid)
			# Small XP — a breadcrumb is connective tissue, not a leveling shortcut.
			assert_lte(
				int(q.rewards.get("xp", 0)),
				BREADCRUMB_XP_CAP,
				"breadcrumb %s pays small XP (<= %d)" % [qid, BREADCRUMB_XP_CAP]
			)
			# It must land on a REAL neighbour flight node (not the home village roost).
			var best := INF
			var best_id := ""
			for n in nodes:
				var d: float = reach_pt.distance_to(n["pos"])
				if d < best:
					best = d
					best_id = str(n["id"])
			assert_lt(
				best,
				HUB_MATCH_RADIUS,
				"breadcrumb %s reaches a real flight hub (nearest %s)" % [qid, best_id]
			)
			assert_ne(
				best_id,
				"village",
				"breadcrumb %s points at a NEIGHBOUR, not the home village" % qid
			)


# ---- 10. INTEGRITY: prereq wiring is acyclic + in-set; kill targets are spawned --------------
func test_zone_quest_prereq_integrity() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var quests: Dictionary = loaded["quests"]
	for sheet in _zone_sheets():
		if not _has_full_ledger(sheet):
			continue
		var zone_id := str(sheet["id"])
		for qid in _zone_quest_ids(sheet):
			if not quests.has(qid):
				continue
			var q = quests[qid]
			# Prereq resolves and never self-references (a cycle floor — full DAG proof is global).
			var prereq := str(q.prerequisite_quest)
			if prereq != "":
				assert_true(
					quests.has(prereq),
					"zone '%s' quest %s prereq %s exists" % [zone_id, qid, prereq]
				)
				assert_ne(prereq, qid, "zone '%s' quest %s is not its own prereq" % [zone_id, qid])
			assert_gt(int(q.rewards.get("xp", 0)), 0, "zone '%s' quest %s pays XP" % [zone_id, qid])


# ---- 11. XP-BAND SANITY: elite quests pay a premium over solo peers in the same band ---------
func test_zone_elite_quests_pay_a_visible_premium() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var quests: Dictionary = loaded["quests"]
	for sheet in _zone_sheets():
		if not _has_full_ledger(sheet):
			continue
		var zone_id := str(sheet["id"])
		# Compare within the L1-10 content arc where both solo and elite quests exist.
		var elite_xp: Array = []
		var solo_xp: Array = []
		for qid in _zone_quest_ids(sheet):
			if not quests.has(qid):
				continue
			var q = quests[qid]
			if int(q.min_level) < 1 or int(q.min_level) > 10:
				continue
			if int(q.recommended_players) > 1:
				elite_xp.append(int(q.rewards.get("xp", 0)))
			else:
				solo_xp.append(int(q.rewards.get("xp", 0)))
		if elite_xp.is_empty() or solo_xp.is_empty():
			continue
		var avg_elite: float = 0.0
		for v in elite_xp:
			avg_elite += v
		avg_elite /= elite_xp.size()
		var avg_solo: float = 0.0
		for v in solo_xp:
			avg_solo += v
		avg_solo /= solo_xp.size()
		assert_gt(
			avg_elite,
			avg_solo,
			(
				"zone '%s' elite quests must pay a premium (avg elite %.0f > avg solo %.0f)"
				% [zone_id, avg_elite, avg_solo]
			)
		)


# =============================================================================================
# T-627 SOLO-PATH COVERAGE ORACLES. The xp_ledger sums XP by declared min_level, blind to WHERE the
# source lives or WHAT gates it (a whole L10-20 band can read "OK" on the ledger while every source
# is an instance-only mob behind a group-gated dungeon). These oracles add the location/gating check
# the sum can't see: for the zone that owns the full 1-20 spine (declares a `highland_solo` chain),
# they assert the L10-20 band is a WALKABLE SOLO path — open-world (non-instance) mobs populate
# every level 10-19, and the declared solo spine is completable WITHOUT the Hollowed Crypt (every
# objective targets a reachable open-world mob/node or a reach point), parallel to the crypt
# group chain, which must stay intact. Fail CLOSED so a future zonegen/content run can't let the
# 8-level solo dead-end (or its q_ashmoor_first_blood-class min_level inversion) reappear.


func _has_highland(sheet: Dictionary) -> bool:
	return (sheet.get("quest_chain", {}) as Dictionary).has("highland_solo")


# Every mob_id spawned via spawns.json (the overworld) -> {level, elite}. This is the OPEN-WORLD
# set: instance mobs (data/instances/*.json, seeded only on a party's descent) are excluded.
func _open_world_mobs() -> Dictionary:
	var doc: Variant = _load_json("res://data/mobs/spawns.json")
	var out: Dictionary = {}
	for e in (doc as Dictionary).get("spawns", []):
		var mob := _mob(str(e.get("mob_file", "")))
		var mid := str(mob.get("mob_id", ""))
		if mid != "":
			out[mid] = {"level": int(mob.get("level", 1)), "elite": bool(mob.get("elite", false))}
	return out


# Every mob_id that only exists inside an instance file (the crypt/vault group content).
func _instance_mob_ids() -> Dictionary:
	var out: Dictionary = {}
	var dir := DirAccess.open("res://data/instances")
	if dir == null:
		return out
	for name in dir.get_files():
		if not name.ends_with(".json"):
			continue
		var doc: Variant = _load_json("res://data/instances/%s" % name)
		if not (doc is Dictionary):
			continue
		for e in (doc as Dictionary).get("spawns", []):
			var mob := _mob(str(e.get("mob_file", "")))
			var mid := str(mob.get("mob_id", ""))
			if mid != "":
				out[mid] = true
	return out


# Every item id a solo player can obtain in the OPEN WORLD (mob loot in spawns.json + gather nodes).
func _open_world_collect_items() -> Dictionary:
	var out: Dictionary = {}
	var doc: Variant = _load_json("res://data/mobs/spawns.json")
	for e in (doc as Dictionary).get("spawns", []):
		var mob := _mob(str(e.get("mob_file", "")))
		for entry in mob.get("loot", []):
			out[str(entry.get("item_id", ""))] = true
	var nodes: Variant = _load_json("res://data/gather/nodes.json")
	if nodes is Dictionary:
		for n in nodes.get("nodes", []):
			out[str(n.get("item_id", ""))] = true
	return out


# ---- 12. ROSTER: every level in the L10-20 band has a NON-ELITE open-world (solo) mob -----------
func test_zone_l10_20_band_has_open_world_solo_mobs() -> void:
	var open_world := _open_world_mobs()
	for sheet in _zone_sheets():
		if not _has_highland(sheet):
			continue
		var zone_id := str(sheet["id"])
		# Per-level roster check across the whole band — the strongest form of "not a dungeon-only
		# gate": a solo player has a level-appropriate open-world target at every step 10..19.
		for lvl in range(HIGHLAND_LO, HIGHLAND_HI):
			var found := false
			for mid in open_world:
				var m: Dictionary = open_world[mid]
				if int(m["level"]) == lvl and not bool(m["elite"]):
					found = true
					break
			assert_true(
				found,
				(
					"zone '%s' L%d has NO non-elite open-world mob — the L10-20 solo dead-zone (T-627)"
					% [zone_id, lvl]
				)
			)


# ---- 13. SPINE: the declared solo quest chain is walkable WITHOUT the crypt instance ------------
func test_zone_solo_spine_is_crypt_free_and_reachable() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var quests: Dictionary = loaded["quests"]
	var open_world := _open_world_mobs()
	var instance_only := _instance_mob_ids()
	var collectables := _open_world_collect_items()
	for sheet in _zone_sheets():
		if not _has_highland(sheet):
			continue
		var zone_id := str(sheet["id"])
		var spine: Array = (sheet.get("quest_chain", {}) as Dictionary).get("highland_solo", [])
		assert_gte(spine.size(), 8, "zone '%s' fields an 8+ quest solo spine" % zone_id)
		var band_lo := false  # a spine quest in [10,15)
		var band_hi := false  # a spine quest in [15,20)
		for qid in spine:
			assert_true(quests.has(str(qid)), "zone '%s' spine quest %s loads" % [zone_id, qid])
			if not quests.has(str(qid)):
				continue
			var q = quests[str(qid)]
			# Solo-completable: the spine itself must never be group-gated.
			assert_lte(
				int(q.recommended_players),
				1,
				"zone '%s' spine quest %s must be solo (recommended_players <= 1)" % [zone_id, qid]
			)
			# Reachability: min_level never drops below its prereq's floor (the q_ashmoor_first_blood
			# min_level-fiction class of bug — a quest tagged L15 but actually gated at L19).
			var prereq := str(q.prerequisite_quest)
			if prereq != "" and quests.has(prereq):
				assert_gte(
					int(q.min_level),
					int(quests[prereq].min_level),
					(
						"zone '%s' spine quest %s min_level %d is below its prereq %s floor %d"
						% [zone_id, qid, int(q.min_level), prereq, int(quests[prereq].min_level)]
					)
				)
			var ml := int(q.min_level)
			if ml >= 10 and ml < 15:
				band_lo = true
			elif ml >= 15 and ml < 20:
				band_hi = true
			# Every objective must be solo-reachable in the OPEN WORLD — no crypt-instance target.
			for obj: Dictionary in q.objectives:
				var t := str(obj.get("type", ""))
				var target := str(obj.get("target", ""))
				if t == "kill":
					assert_true(
						open_world.has(target),
						(
							"zone '%s' spine quest %s kills %s, not an open-world mob (T-627)"
							% [zone_id, qid, target]
						)
					)
					assert_false(
						instance_only.has(target) and not open_world.has(target),
						(
							"zone '%s' spine quest %s targets crypt-instance mob %s"
							% [zone_id, qid, target]
						)
					)
				elif t == "collect":
					assert_true(
						collectables.has(target),
						(
							"zone '%s' spine quest %s collects %s with no open-world producer"
							% [zone_id, qid, target]
						)
					)
				elif t == "reach":
					var pt := Vector2(float(obj.get("x", 0.0)), float(obj.get("y", 0.0)))
					assert_gt(
						pt.distance_to(_CRYPT_PORCH),
						5.0,
						"zone '%s' spine quest %s reach routes to the crypt porch" % [zone_id, qid]
					)
		assert_true(band_lo, "zone '%s' solo spine covers the L10-15 band" % zone_id)
		assert_true(band_hi, "zone '%s' solo spine covers the L15-20 band" % zone_id)


# ---- 14. XP SOURCE: each L10-20 ledger band has a SOLO quest whose target is an open-world mob ---
# The ledger's XP sum can't prove this — it counts a quest's XP by min_level even when the quest's
# only target is an instance mob. This asserts the roster backs the sum: a solo, open-world kill
# quest actually exists in each band.
func test_zone_l10_20_bands_have_a_walkable_solo_xp_source() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var quests: Dictionary = loaded["quests"]
	var open_world := _open_world_mobs()
	for sheet in _zone_sheets():
		if not _has_highland(sheet):
			continue
		var zone_id := str(sheet["id"])
		var spine: Array = (sheet.get("quest_chain", {}) as Dictionary).get("highland_solo", [])
		for band in [[10, 15], [15, 20]]:
			var ok := false
			for qid in spine:
				if not quests.has(str(qid)):
					continue
				var q = quests[str(qid)]
				if int(q.recommended_players) > 1:
					continue
				if int(q.min_level) < band[0] or int(q.min_level) >= band[1]:
					continue
				for obj: Dictionary in q.objectives:
					if str(obj.get("type", "")) != "kill":
						continue
					var m: Dictionary = open_world.get(str(obj.get("target", "")), {})
					if not m.is_empty() and not bool(m.get("elite", false)):
						ok = true
			assert_true(
				ok,
				(
					"zone '%s' L%d-%d has no solo quest killing an open-world mob (ledger-blind gap)"
					% [zone_id, band[0], band[1]]
				)
			)


# ---- 15. BOTH PATHS: the crypt group chain stays intact as the parallel group option ------------
func test_zone_group_crypt_chain_stays_intact() -> void:
	var loaded: Dictionary = _CONTENT.load_all("res://data")
	var quests: Dictionary = loaded["quests"]
	var instance_only := _instance_mob_ids()
	for sheet in _zone_sheets():
		if not _has_highland(sheet):
			continue
		var zone_id := str(sheet["id"])
		var bridge: Array = (sheet.get("quest_chain", {}) as Dictionary).get("bridge_quests", [])
		assert_gt(bridge.size(), 0, "zone '%s' keeps the crypt group chain" % zone_id)
		# At least one bridge quest still routes through the crypt instance (the group path is not
		# accidentally deleted or re-pointed to the overworld by the solo pass).
		var routes_through_crypt := false
		for qid in bridge:
			if not quests.has(str(qid)):
				continue
			for obj: Dictionary in quests[str(qid)].objectives:
				if (
					str(obj.get("type", "")) == "kill"
					and instance_only.has(str(obj.get("target", "")))
				):
					routes_through_crypt = true
		assert_true(
			routes_through_crypt,
			(
				"zone '%s' group chain still routes through the crypt instance (both paths exist)"
				% zone_id
			)
		)
