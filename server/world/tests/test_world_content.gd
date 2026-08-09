extends "res://addons/gut/test.gd"
# Pure content-query helpers (content_query.gd) over the real seed content + mob alias loading.
# Content is loaded directly via content_registry (decoupled from the world node — TD-002 moved the
# boot content-load into world_rpc.setup; see test_world_rpc.gd).

const CQ = preload("res://scripts/content/content_query.gd")
const _CONTENT = preload("res://scripts/content/content_registry.gd")
const Main = preload("res://scripts/main.gd")

var _q: Dictionary  # quests
var _n: Dictionary  # npcs
var _i: Dictionary  # items
var _m: Dictionary  # spawned mobs
var _gn: Dictionary  # gather nodes


func before_each() -> void:
	var loaded := _CONTENT.load_all("res://data")
	assert_eq(loaded["errors"], [], "real seed content loads with no errors")
	_q = loaded["quests"]
	_n = loaded["npcs"]
	_i = loaded["items"]
	_m = loaded["mobs"]
	_gn = loaded["gather_nodes"]


func test_quest_to_dict_shape_matches_master_contract() -> void:
	var d: Dictionary = CQ.quest_to_dict(_q["q001"])
	assert_eq(d["id"], "q001")
	assert_true(d.has("min_level"))
	assert_true(d.has("prerequisite_quest"))
	assert_true(d.has("objectives"))
	assert_true(d.has("rewards"))


func test_kill_quest_defs_filters_by_target() -> void:
	var defs: Dictionary = CQ.kill_quest_defs(_q, "mob_wolf")
	assert_true(defs.has("q001"), "q001 has a kill objective for mob_wolf")
	assert_eq(CQ.kill_quest_defs(_q, "mob_x"), {}, "no quest matches a bogus alias")


# T-426: ability_quest_defs filters quests by a `use_ability` objective's ability icon slug.
func _quest_with_ability(qid: String, slug: String):
	var q = _q["q001"].get_script().new()
	q.id = qid
	q.objectives = [{"type": "use_ability", "target": slug, "count": 1}]
	return q


func test_ability_quest_defs_filters_by_slug() -> void:
	var quests := {"q_ab": _quest_with_ability("q_ab", "heroic_strike")}
	var defs: Dictionary = CQ.ability_quest_defs(quests, "heroic_strike")
	assert_true(
		defs.has("q_ab"), "the quest with a use_ability objective for heroic_strike matches"
	)
	assert_eq(CQ.ability_quest_defs(quests, "fireball"), {}, "a different slug matches nothing")
	assert_eq(CQ.ability_quest_defs(quests, ""), {}, "empty slug matches nothing")


func test_ability_quest_defs_wildcard_matches_any_ability() -> void:
	var quests := {"q_any": _quest_with_ability("q_any", "*")}
	assert_true(CQ.ability_quest_defs(quests, "fireball").has("q_any"), "'*' matches any ability")
	assert_true(CQ.ability_quest_defs(quests, "heroic_strike").has("q_any"), "'*' matches any slug")
	assert_eq(CQ.ability_quest_defs(quests, "").size(), 0, "still no match for an empty slug")


# T-426: the tutorial chain loads clean (before_each asserts zero content errors), is given by the
# Drillmaster, chains q_tut_01 -> q_tut_02, and teaches the full verb set across the two quests.
func test_tutorial_chain_loads_and_teaches_all_verbs() -> void:
	assert_true(_q.has("q_tut_01") and _q.has("q_tut_02"), "both tutorial quests loaded")
	assert_eq(str(_q["q_tut_02"].prerequisite_quest), "q_tut_01", "q_tut_02 chains off q_tut_01")
	assert_true("q_tut_01" in _n["npc_drillmaster"].gives_quests, "Hale gives the tutorial")
	var verbs := {}
	for qid in ["q_tut_01", "q_tut_02"]:
		for obj in _q[qid].objectives:
			verbs[str(obj["type"])] = true
	for verb in ["reach", "kill", "collect", "equip", "use_ability"]:
		assert_true(verbs.has(verb), "the tutorial teaches the '%s' verb" % verb)
	assert_true(
		str(_q["q_tut_02"].description).to_lower().contains("find your people"),
		"Hale's final beat hands the graduate to social discovery"
	)


# T-293: the three elite bounties load, lint clean (before_each asserts zero errors), target the
# T-294 elite aliases, and are flagged repeatable + bounty so the board can list + re-accept them.
func test_bounty_quests_present_and_repeatable() -> void:
	for qid in ["qb01", "qb02", "qb03"]:
		assert_true(_q.has(qid), "bounty %s loaded" % qid)
		assert_true(_q[qid].repeatable, "%s is repeatable" % qid)
		assert_true(_q[qid].bounty, "%s is a bounty" % qid)
	assert_true(CQ.quest_to_dict(_q["qb01"]).get("repeatable", false), "repeatable flows to master")


func test_bounty_targets_are_elite_aliases() -> void:
	for pair in [["qb01", "mob_greymaw"], ["qb02", "mob_grexrok"], ["qb03", "mob_elderthorn"]]:
		var defs: Dictionary = CQ.kill_quest_defs(_q, str(pair[1]))
		assert_true(defs.has(str(pair[0])), "%s hunts %s" % [pair[0], pair[1]])


func test_bounty_defs_lists_board_summaries() -> void:
	var list: Array = CQ.bounty_defs(_q)
	assert_eq(list.size(), 3, "exactly the three elite bounties")
	var first: Dictionary = list[0]
	assert_eq(str(first["quest_id"]), "qb01", "sorted by id")
	assert_eq(str(first["target"]), "mob_greymaw")
	assert_true(int(first["xp"]) > 250, "group reward beats a solo quest's 250 xp")
	assert_eq(int(first["recommended_players"]), 3)
	assert_false(str(first["location_hint"]).is_empty(), "carries a location hint")


func test_bounty_board_npc_is_a_service_hub() -> void:
	assert_true(_n.has("npc_hk_bounty_board"), "the Highkeep board NPC exists")
	assert_eq(str(_n["npc_hk_bounty_board"].service), "bounty", "it is a bounty service hub")


# T-420: the real, wearable warrior PLATE set — head/chest/legs/shoulders — validates (before_each
# asserts zero content errors), carries armor_type "plate", and sits in its equip slot. This is what
# makes the T-224 plate GLBs reachable.
func test_ironward_plate_set_is_a_valid_wearable_set() -> void:
	var expect := {
		"itm_ironward_helm": "head",
		"itm_ironward_cuirass": "chest",
		"itm_ironward_greaves": "legs",
		"itm_ironward_pauldrons": "shoulders",
	}
	for id: String in expect:
		assert_true(_i.has(id), "%s loaded" % id)
		assert_eq(str(_i[id].armor_type), "plate", "%s is plate-family" % id)
		assert_eq(str(_i[id].slot), str(expect[id]), "%s sits in its slot" % id)
		assert_true(int(_i[id].stats.get("armor", 0)) > 0, "%s grants armor" % id)


# T-420: the plate set is REACHABLE — the Skeletal Warrior drops every piece (independent per-item
# rolls), so a player can farm + assemble + equip the set (the T-224 fit/screenshot is the pilot's).
func test_ironward_plate_set_drops_from_the_skeletal_warrior() -> void:
	var loot_ids := {}
	var file := FileAccess.open("res://data/mobs/skeletal_warrior.json", FileAccess.READ)
	assert_true(file != null, "the skeletal warrior mob def exists")
	var data: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()
	for entry: Dictionary in data.get("loot", []):
		loot_ids[str(entry.get("item_id"))] = float(entry.get("chance", 0.0))
	var pieces := ["itm_ironward_helm", "itm_ironward_cuirass", "itm_ironward_greaves"]
	pieces.append("itm_ironward_pauldrons")
	for id in pieces:
		assert_true(loot_ids.has(id), "%s is on the skeletal warrior loot table" % id)
		assert_true(loot_ids[id] > 0.0, "%s has a real drop chance" % id)


# T-224 (mage + priest sets): the wearable cloth-caster sets — mage robe (armor_type "robe") and
# priest vestment (armor_type "vestment") — validate, carry their own family, and sit in slot. This
# is what makes the T-224 caster GLBs reachable; the distinct armor_type keeps generic cloth intact.
func test_caster_armor_sets_are_valid_wearable_sets() -> void:
	var expect := {
		"itm_arcanist_cowl": ["head", "robe"],
		"itm_arcanist_robe": ["chest", "robe"],
		"itm_arcanist_leggings": ["legs", "robe"],
		"itm_sanctified_hood": ["head", "vestment"],
		"itm_sanctified_vestment": ["chest", "vestment"],
		"itm_sanctified_skirts": ["legs", "vestment"],
	}
	for id: String in expect:
		assert_true(_i.has(id), "%s loaded" % id)
		assert_eq(str(_i[id].slot), str(expect[id][0]), "%s sits in its slot" % id)
		assert_eq(str(_i[id].armor_type), str(expect[id][1]), "%s carries its family" % id)
		assert_true(int(_i[id].stats.get("armor", 0)) > 0, "%s grants armor" % id)


# T-224 (mage + priest sets): the caster sets are REACHABLE — the Skeletal Warrior drops every piece
# (independent per-item rolls), so a caster can farm + assemble + equip a set they can see.
func test_caster_armor_sets_drop_from_the_skeletal_warrior() -> void:
	var loot_ids := {}
	var file := FileAccess.open("res://data/mobs/skeletal_warrior.json", FileAccess.READ)
	assert_true(file != null, "the skeletal warrior mob def exists")
	var data: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()
	for entry: Dictionary in data.get("loot", []):
		loot_ids[str(entry.get("item_id"))] = float(entry.get("chance", 0.0))
	var pieces := [
		"itm_arcanist_cowl",
		"itm_arcanist_robe",
		"itm_arcanist_leggings",
		"itm_sanctified_hood",
		"itm_sanctified_vestment",
		"itm_sanctified_skirts",
	]
	for id in pieces:
		assert_true(loot_ids.has(id), "%s is on the skeletal warrior loot table" % id)
		assert_true(loot_ids[id] > 0.0, "%s has a real drop chance" % id)


func test_load_mobs_sets_alias() -> void:
	var w = Main.new()
	w._load_mobs()
	assert_eq(w._mobs[1001].mob_id, "mob_dummy", "dummy mob loads its mob_id alias")
	w.free()


func test_at_turnin_npc_proximity() -> void:
	# q001's turn-in NPC is npc_farmer_geld at (5, 2).
	var quest = _q["q001"]
	assert_true(CQ.at_turnin_npc(_n, quest, Vector3(5.0, 2.0, 0.0), 3.0), "at NPC → true")
	assert_false(CQ.at_turnin_npc(_n, quest, Vector3(99.0, 99.0, 0.0), 3.0), "far → false")


func test_item_registry_shape() -> void:
	var reg: Dictionary = CQ.item_registry(_i)
	assert_true(reg.has("itm_iron_sword"))
	assert_true(reg["itm_iron_sword"].has("slot"))
	assert_true(reg["itm_iron_sword"].has("stackable"))
	assert_true(reg["itm_iron_sword"].has("max_stack"))


func test_near_npc() -> void:
	# npc_farmer_geld is at (5, 2).
	assert_true(CQ.near_npc(_n, "npc_farmer_geld", Vector3(5.0, 2.0, 0.0), 3.0), "within → true")
	assert_false(CQ.near_npc(_n, "npc_farmer_geld", Vector3(50.0, 50.0, 0.0), 3.0), "far → false")
	assert_false(CQ.near_npc(_n, "npc_unknown", Vector3(5.0, 2.0, 0.0), 3.0), "unknown → false")


func test_npc_to_dict() -> void:
	var d: Dictionary = CQ.npc_to_dict(_n["npc_farmer_geld"])
	assert_eq(d["id"], "npc_farmer_geld")
	assert_true(d.has("gives_quests"))
	assert_true(d.has("talk_text"))


func test_all_quest_defs_keys_every_quest() -> void:
	var defs: Dictionary = CQ.all_quest_defs(_q)
	assert_true(defs.has("q001"))
	assert_eq(defs["q001"]["id"], "q001")


# ---- T-038: quest-log enrichment ----


func test_enrich_quest_log_pairs_progress_with_content() -> void:
	var raw := [{"quest_id": "q001", "state": "active", "progress": [3, 5, 1, 0]}]
	var enriched: Array = CQ.enrich_quest_log(raw, _q)
	assert_eq(enriched[0]["title"], "Cull the Wolves")
	assert_eq(enriched[0]["state"], "active")
	var obj0: Dictionary = enriched[0]["objectives"][0]
	assert_eq(obj0["desc"], "Slay gray wolves")
	assert_eq(obj0["current"], 3)
	assert_eq(obj0["required"], 8)


func test_enrich_quest_log_unknown_quest_fallback() -> void:
	var enriched: Array = CQ.enrich_quest_log(
		[{"quest_id": "q999", "state": "active", "progress": []}], {}
	)
	assert_eq(enriched[0]["title"], "q999")
	assert_eq(enriched[0]["objectives"], [])


func test_npc_indicators_from_quest_state() -> void:
	var npcs := {
		"giver": {"id": "giver", "gives_quests": ["q"]},
		"turnin": {"id": "turnin", "gives_quests": []},
	}
	var quest := {
		"id": "q",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "giver",
		"turnin_npc": "turnin",
		"objectives": [{"type": "kill", "target": "wolf", "count": 2}],
	}
	var index := {"giver": {"q": quest}, "turnin": {"q": quest}}
	var available: Dictionary = CQ.npc_indicators_from_state(npcs, index, [], 1)
	assert_eq(available["giver"], "!", "unaccepted eligible quest is available")
	var active := [{"quest_id": "q", "state": "active", "progress": [1]}]
	var incomplete: Dictionary = CQ.npc_indicators_from_state(npcs, index, active, 1)
	assert_eq(incomplete["turnin"], "?grey", "active incomplete quest marks turn-in")
	var complete := [{"quest_id": "q", "state": "active", "progress": [2]}]
	var ready: Dictionary = CQ.npc_indicators_from_state(npcs, index, complete, 1)
	assert_eq(ready["turnin"], "?", "completed objectives mark turn-in ready")


# ---- T-039: inventory enrichment ----


func test_enrich_inventory_adds_name_and_int_count() -> void:
	# DB returns item_count/slot_index as strings (T-045 / TD-001) — enrichment normalizes to int.
	var raw := [
		{"slot_type": "bag", "slot_index": "1", "item_id": "itm_wolf_pelt", "item_count": "5"}
	]
	var enriched: Array = CQ.enrich_inventory(raw, _i)
	assert_eq(enriched[0]["name"], "Wolf Pelt")
	assert_eq(enriched[0]["count"], 5)
	assert_eq(enriched[0]["slot_index"], 1)
	assert_eq(typeof(enriched[0]["count"]), TYPE_INT, "count normalized to int")
	# T-233: tooltip fields threaded through alongside name/rarity.
	assert_eq(enriched[0]["slot"], "none")
	assert_eq(enriched[0]["vendor_value"], 2)
	assert_eq(enriched[0]["description"], "A coarse gray pelt.")
	assert_eq(enriched[0]["stats"], {})


func test_enrich_inventory_unknown_item_fallback() -> void:
	var enriched: Array = CQ.enrich_inventory(
		[{"slot_type": "bag", "slot_index": 0, "item_id": "itm_x", "item_count": 1}], {}
	)
	assert_eq(enriched[0]["name"], "itm_x")


# ---- T-046: reach proximity ----


func test_reach_targets_at() -> void:
	# q001 has a reach objective: loc_old_well at (42, -13), radius 3.
	assert_true(
		CQ.reach_targets_at(_q, Vector3(42.0, -13.0, 0.0)).has("loc_old_well"), "inside radius"
	)
	assert_eq(CQ.reach_targets_at(_q, Vector3(0.0, 0.0, 0.0)), [], "far away → no targets")


# ---- T-601/T-602: collect-objective targets must have an IN-LEVEL-RANGE source ----
# content_registry.validate_sources (T-073) already proves a collect target is producible SOMEWHERE
# in the game — that's how q005/q_wold_foul_wellspring shipped uncompletable at their own gate: the
# only producer (bloodthorn_lasher, L7) was 6 levels above q005's min_level 1. This test closes that
# gap: every collect target must be reachable at or below the quest's own min_level + a small
# headroom band, from a source a player can actually use at that level — a gather node (no combat
# gate, always in range) or a mob loot table whose mob is itself <= min_level + headroom. A
# quest-provided item (delivery pattern, T-058) always counts — the player never has to "find" it.
# ---- T-615: the 1-10 breadcrumb chain must have no dead level ----
# game-direction.md §3's Session-clock contract needs a "one more quest" hook within a level or two
# of every ding across the starter arc. A level with zero acceptable quests (measured: L4 was empty
# between q004/q006 at L2 and q_wold_fevered_flock at L5) resets the player to undirected grinding.
# Repeatable/bounty-board quests don't count — they're a farm loop, not a breadcrumb advance — so the
# gap is measured over the AUTHORED chain quests only. Fails CLOSED so a future ≥2-level hole (two
# consecutive levels with no chain quest) can't ship silently.
func test_no_dead_level_in_the_1_to_10_breadcrumb_chain() -> void:
	var levels := {}
	for qid in _q:
		var quest = _q[qid]
		if bool(quest.repeatable) or bool(quest.bounty):
			continue
		var ml := int(quest.min_level)
		if ml >= 1 and ml <= 10:
			levels[ml] = true
	var present: Array = levels.keys()
	present.sort()
	assert_gt(present.size(), 0, "the starter arc has authored chain quests")
	for i in range(1, present.size()):
		var gap: int = int(present[i]) - int(present[i - 1])
		assert_lte(
			gap,
			2,
			(
				(
					"breadcrumb gap: no chain quest between L%d and L%d (>=2 dead levels) — a fresh "
					+ "character dings into undirected grinding here"
				)
				% [int(present[i - 1]), int(present[i])]
			)
		)


func test_quest_collect_targets_have_an_in_level_range_source() -> void:
	const HEADROOM := 2  # matches the crank-prep band ("min_level + 2")
	for qid in _q:
		var quest = _q[qid]
		var min_level := int(quest.min_level)
		for objective in quest.objectives:
			if str(objective.get("type", "")) != "collect":
				continue
			var target := str(objective.get("target", ""))
			var reachable := false
			var why := "no source found"

			for entry in quest.provided_items:
				if entry is Dictionary and str(entry.get("item", "")) == target:
					reachable = true
					why = "quest-provided"

			if not reachable:
				for node_id in _gn:
					if str(_gn[node_id].get("item_id", "")) == target:
						reachable = true
						why = "gather node %s" % node_id
						break

			if not reachable:
				for mob_id in _m:
					var mob: Dictionary = _m[mob_id]
					# mob_dummy/training_effigy carry no "level" (non-combat teaching props) —
					# treat as level 0 (trivially in range), not "missing = unreachable".
					var mob_level := int(mob.get("level", 0))
					if mob_level > min_level + HEADROOM:
						continue
					for loot in mob.get("loot", []):
						if loot is Dictionary and str(loot.get("item_id", "")) == target:
							reachable = true
							why = "mob %s (L%d)" % [mob_id, mob_level]
							break
					if reachable:
						break

			assert_true(
				reachable,
				(
					"quest %s (min_level %d) collect target %s has no source at/below L%d — %s"
					% [qid, min_level, target, min_level + HEADROOM, why]
				)
			)
