extends GutTest

const _CR = preload("res://scripts/content/content_registry.gd")
const _CQ = preload("res://scripts/content/content_query.gd")


func _data_path() -> String:
	return ProjectSettings.globalize_path("res://data")


func _load_seed() -> Dictionary:
	return _CR.load_all(_data_path())


func _validate_seed_with(quests, items, npcs) -> Array:
	var loaded := _load_seed()
	return _CR.validate(
		loaded["quests"] if quests == null else quests,
		loaded["items"] if items == null else items,
		loaded["npcs"] if npcs == null else npcs
	)


func _has_error(errors: Array, needle: String) -> bool:
	for error in errors:
		if str(error).find(needle) >= 0:
			return true
	return false


func test_load_counts():
	var loaded := _load_seed()
	# T-040: q001 demo + 5 hand-written quests; +11 items, +6 NPCs.
	# T-047: + q007 proving-grounds tutorial quest + npc_drillmaster (the integration-harness fixture).
	# T-065: + npc_arcanist + npc_cleric (class trainers) -> 11 NPCs; 45 talents (T-064).
	# T-144: + 14 Highkeep city NPCs (class + profession trainers, services, regent, guards) -> 25.
	# ...T-209 +8 citizens -> 42; T-213 +3 village children -> 45; T-215 replaces 2 gate
	# sentries with watch IDs and adds 8 further watch posts -> 53.
	# T-293: + qb01..qb03 elite bounties; T-335: + q_crypt_restless_dead -> 15.
	# T-352: + q_rift_vault_counted + q_ashmoor_first_blood (the rift-arrival chain) -> 17.
	# T-356: + 10 L5-10 "Hollowing stirs" mid-game quests (q_wold_*) filling the empty band -> 27.
	# T-357: + the 5-quest Era-1 capstone arc -> 32.
	# T-358: + the 6-quest Ashmoor Syndicate street arc (L20-40 Era-2 tier) -> 38.
	# T-411: + 2 repeatable bonus-objective "cull" quests (q_ashmoor_cull_the_racket L20-40,
	# q_wold_thin_the_pack L10-15) — the fun-audit-2 burst sources -> 40.
	# T-426: + 2 tutorial quests (q_tut_01 First Steps, q_tut_02 Kit Up) — the teaching onramp -> 42.
	# T-426 slice 4: + q_tut_03 Read the Fight (the tactical interrupt teaching encounter) -> 43.
	# T-615: + q_wold_stray_wolves (L3) + q_wold_mend_the_fold (L4) — bridge the empty L4 breadcrumb
	# gap between q004/q006 (L2) and q_wold_fevered_flock (L5) -> 45.
	# T-622: + 8 L6-10 Heartwold solo quests (smiths_copper, timber_run, cull_the_diggings,
	# thornroot_cuttings, wardens_toll, iron_levy, deepwood_survey, last_patrol) closing the
	# elite-heavy L7-10 solo gap + 3 breadcrumbs (road_to_highkeep, deep_gate_road, kingsroad_ashmoor)
	# handing toward the T-596 neighbour hubs -> 56. (Zone total lands at 48 of the 40-60 budget; the
	# L10-20 open-world solo density is completed by T-627, not here.)
	# T-627: + the L10-20 Heartwold solo spine (10 open-world quests: dire_treeline, darkwood_stalkers,
	# grove_rot, moor_watch, fenmire_cull, barrow_hounds, crag_reavers, apex_predators,
	# blight_at_the_rift, moor_road_ashmoor) + 2 optional Elite hunts (deepwood_matriarch,
	# moorlord_grymm) targeting the new open-world L10-20 mob wing -> 68. (Zone total now 60, the
	# WoW Loremaster ceiling.)
	# T-719: + q_tut_04 (The Shallow Graves) — the tutorial capstone mini-dungeon -> 69.
	assert_eq(loaded["quests"].size(), 69)
	# T-216: letter + vault voucher -> 17. T-319: + 3 class starting weapons
	# (itm_starter_sword/staff/mace) -> 20. T-333: +9 dungeon rewards -> 29.
	# T-341: + 6 crypt undead grave goods -> 35.
	# T-349: + 5 Ashmoor Syndicate street loot (shilling/gin/knuckles/truncheon/sigil chalk) -> 40.
	# T-351: + 2 Era-2 caster FOCUS items (occult sigil cane + medium reliquary) -> 42.
	# T-352: + itm_rift_worn_coat + itm_leadpipe (the arrival-chain rewards) -> 44.
	# T-353: + itm_maldrath_hollow_crown (epic-tier def for the rift gear-carry; on no loot
	# table until the raid tier ships — S4.1 keeps the obtainable demo loot capped at rare) -> 45.
	# T-357: + 5 rare-tier capstone rewards (osric_ward_censer, gravewarden_hauberk,
	# hollowing_ward_charm, deepvault_hood, riftward_blade) — all at/below the rare cap (§4.1) -> 50.
	# T-414: + 3 herbs + venom-gland reagent + 2 healing potions + ration + field repair kit -> 58.
	# T-414 slice 2: + iron ore + rough timber + broadsword + buckler + smith's repair kit -> 63.
	# T-420: + the Ironward warrior PLATE set (helm/cuirass/greaves/pauldrons) -> 67.
	# T-224 (mage + priest sets): + the mage robe set (cowl/robe/leggings) + priest vestment set
	# (hood/vestment/skirts) -> 73.
	# T-426: + itm_practice_token (the tutorial loot-verb collectible) -> 74.
	# T-473: + 5 Era-1 RAID epics (sentinel warplate/gravewall, dirgemother knell/palls,
	# hollow-king greaves) — the weekly Vault tier the T-353 crown anchors -> 79.
	# T-538: + the bespoke rift loot set — 3 rarity bands x 4 (riftmarked/riftbound/riftforged),
	# replacing the six borrowed crypt blues in the rift schedule -> 91.
	# T-659: + 3 Crystal Lake fish + one cooked-fish meal -> 95.
	# T-616: + itm_wolf_fang (beast vendor-grey) + itm_worn_kobold_coin (coin-on-humanoid proxy) —
	# the loot-band retrofit adds a vendor-grey/coin tier that was absent from the 1-10 zone -> 97.
	# T-677: + itm_herb_emberbloom + itm_gem_raw + itm_timber_heartwood — the herb/ore/timber rare
	# cross-find items minted by the gather variable-ratio retrofit (bonus_find procs) -> 100.
	# T-685: + itm_potion_potent_healing + itm_smith_gemset_charm + itm_smith_heartwood_longbow —
	# the SINK half: the outputs of the three new recipes that consume the T-677 rare procs -> 103.
	# T-720: + itm_padded_coif (the cloth starter cap every class can wear) -> 104.
	# T-719: + the tutorial-capstone rewards (gravewatch shoulders, sexton's lantern, Marrow's
	# bellhammer) — the L3-4 rung the 1-10 band had no dungeon loot for at all -> 107.
	assert_eq(loaded["items"].size(), 107)
	# T-293: + 2 bounty boards (Highkeep market + village) -> 58.
	# T-317: + npc_village_parson (village church cleric) -> 59.
	# T-352: + npc_ashmoor_urchin (greeter) + npc_ashmoor_sergeant (desk hub) -> 61.
	# T-431: + village and Ashmoor flight masters -> 63.
	# T-596: + Kargrim Deep + Greyrise transit flight masters (continent web hubs) -> 65.
	assert_eq(loaded["npcs"].size(), 65)
	# T-434: one control-toolkit hook per class (48). T-523: trees broadened for the L60
	# cap — 7 tiers + capstones, 52 talents per class -> 156.
	assert_eq(loaded["talents"].size(), 156)


func test_appearance_block_parses_and_validates():
	# T-302: every person carries an `appearance` block (role/seed) driving the client rig+tint;
	# the two bounty-board objects legitimately have none. The allowlist accepts `appearance` (no
	# unknown-key lint), guards are liveried, children are child-scaled, and Scout Mira reads female.
	var loaded := _load_seed()
	var npcs: Dictionary = loaded["npcs"]
	var errors := _validate_seed_with(null, null, null)
	assert_false(_has_error(errors, "appearance"), "appearance is an allowed npc key")
	var with_app := 0
	for id in npcs:
		var n = npcs[id]
		if not n.appearance.is_empty():
			with_app += 1
			assert_true(n.appearance.has("role"), "%s appearance carries a role" % id)
	# T-352: + urchin (child) + desk sergeant (guard) -> 59 styled; the 2 bounty boards are objects.
	# T-596: + the two new continent flight masters (ranger-styled) -> 63 styled.
	assert_eq(with_app, 63, "63 people are styled; the 2 bounty boards are objects")
	assert_eq(npcs["npc_hk_watch_market"].appearance["role"], "guard", "Market Watch is a guard")
	assert_eq(npcs["npc_scout_mira"].appearance.get("sex", "m"), "f", "Scout Mira is female")
	assert_eq(npcs["npc_child_pip"].appearance["role"], "child", "children are child role")


func test_era2_caster_focus_items_ride_the_weapon_ladder():
	# T-351: the two Era-2 caster FOCUS items are weapon-slot gear on the SAME T-230 rarity ladder
	# as firearms/martials (era-direction §11.4) — they carry the `attack` (spell-power) stat and a
	# valid rarity. Buildable-today assertion: a focus sits consistently on the ladder next to the
	# shipped Era-2 martial loot (a RARE focus out-attacks an UNCOMMON Ashmoor martial weapon). The
	# full carry-rescale rule (§4.3 Rule A) + a legendary tier are the balance ticket's job (§4.4).
	var items: Dictionary = _load_seed()["items"]
	const LADDER := ["junk", "common", "uncommon", "rare", "epic", "legendary"]
	for fid in ["itm_occult_sigil_cane", "itm_medium_reliquary"]:
		var it = items.get(fid)
		assert_not_null(it, "%s present" % fid)
		if it == null:
			continue
		assert_eq(it.slot, "weapon", "%s is a weapon-slot focus (same slot as firearms)" % fid)
		assert_true(it.stats.has("attack"), "%s carries the spell-power (attack) stat" % fid)
		assert_true(int(it.stats["attack"]) > 0, "%s has real power" % fid)
		assert_true(LADDER.has(it.rarity), "%s rarity is on the T-230 ladder" % fid)
	# ladder consistency: a RARE focus > an UNCOMMON Ashmoor martial (brass knuckles, attack 11).
	var cane = items["itm_occult_sigil_cane"]
	var knuckles = items["itm_brass_knuckles"]
	assert_eq(cane.rarity, "rare")
	assert_eq(knuckles.rarity, "uncommon")
	assert_true(
		int(cane.stats["attack"]) > int(knuckles.stats["attack"]),
		"a rare focus out-ranks an uncommon martial on the shared ladder"
	)


func test_village_children_on_the_green():
	# T-213: the three kids anchor to the toys on the green by the well (x>5.5, off the
	# road corridor) and each has playful talk_text — living-world dressing, not vendors.
	var npcs: Dictionary = _load_seed()["npcs"]
	for id in ["npc_child_pip", "npc_child_nell", "npc_child_tam"]:
		var n = npcs.get(id)
		assert_not_null(n, "%s present" % id)
		if n != null:
			assert_true(n.x > 5.5 and n.x < 9.0, "%s stands on the green" % id)
			assert_true(n.y > 4.0 and n.y < 8.0, "%s stands on the green" % id)
			assert_ne(n.talk_text, "", "%s has talk_text" % id)
			assert_false(n.trainer, "%s is not a trainer" % id)


# T-715: T-712's L2 banner reads "New ability ready — visit Master-at-Arms Kessa". That promise is
# only real if Kessa carries the starter trainer tag AND stands where the banner implies — beside
# Hale in the hamlet, not 242 m away in Highkeep. Both halves are asserted from content truth.
func test_kessa_is_the_starter_class_trainer_beside_hale():
	var npcs: Dictionary = _load_seed()["npcs"]
	var kessa = npcs.get("npc_trainer")
	var hale = npcs.get("npc_drillmaster")
	assert_not_null(kessa, "Master-at-Arms Kessa is present")
	assert_not_null(hale, "Drillmaster Hale is present")
	if kessa == null or hale == null:
		return
	assert_eq(str(kessa.name), "Master-at-Arms Kessa", "the banner names this NPC")
	assert_eq(str(kessa.service), "trainer:starter", "Kessa sells the starter (L2) trainer tier")
	assert_true(kessa.trainer, "she is still a trainer NPC for the spawn-safety invariant")
	var gap := Vector2(kessa.x - hale.x, kessa.y - hale.y).length()
	assert_true(gap < 5.0, "Kessa stands next to Hale (%.2f m), not in the capital" % gap)
	# The capital trainers keep their own class tags — the starter tag is additional, not a move.
	for id in ["npc_hk_warrior_trainer", "npc_hk_mage_trainer", "npc_hk_priest_trainer"]:
		var cap = npcs.get(id)
		assert_not_null(cap, "%s still stands in Highkeep" % id)
		if cap != null:
			assert_true(str(cap.service).begins_with("trainer:"), "%s still trains" % id)
			assert_ne(str(cap.service), "trainer:starter", "%s keeps its class tag" % id)


func test_five_handwritten_quests_wired():
	# T-040: the five hand-written quests load with their objective types + reward items, lint-clean.
	var loaded := _load_seed()
	var expected := {
		"q002": ["collect"],
		"q003": ["kill"],
		"q004": ["kill"],
		"q005": ["collect"],
		"q006": ["reach", "talk"],
	}
	for quest_id: String in expected:
		assert_true(loaded["quests"].has(quest_id), "%s present" % quest_id)
		var quest = loaded["quests"][quest_id]
		var types := []
		for objective in quest.objectives:
			if not types.has(objective["type"]):
				types.append(objective["type"])
		for t: String in expected[quest_id]:
			assert_true(types.has(t), "%s has a %s objective" % [quest_id, t])
		assert_true(quest.rewards["items"].size() >= 1, "%s grants an item reward" % quest_id)
	# q006 is gated behind q003 (combat basics before PvP).
	assert_eq(str(loaded["quests"]["q006"].prerequisite_quest), "q003")
	# The whole expanded seed is still lint-clean.
	assert_eq(_CR.validate(loaded["quests"], loaded["items"], loaded["npcs"]), [])


func test_highkeep_road_chain_is_complete_and_wired() -> void:
	var loaded := _load_seed()
	var quests: Dictionary = loaded["quests"]
	var expected := {
		"q010": {"prereq": "", "types": ["kill"]},
		"q011": {"prereq": "q010", "types": ["reach"]},
		"q012": {"prereq": "q011", "types": ["talk", "talk", "talk"]},
		"q013": {"prereq": "q012", "types": ["talk"]},
	}
	for quest_id: String in expected:
		assert_true(quests.has(quest_id), "%s present" % quest_id)
		if not quests.has(quest_id):
			continue
		var quest = quests[quest_id]
		assert_eq(str(quest.prerequisite_quest), expected[quest_id]["prereq"])
		var types: Array = quest.objectives.map(func(objective): return objective["type"])
		assert_eq(types, expected[quest_id]["types"], "%s objective sequence" % quest_id)
	assert_eq(int(quests["q013"].rewards.get("coins", 0)), 250, "audience grants coins")
	assert_eq(quests["q013"].provided_items[0]["item"], "itm_letter_of_introduction")
	assert_eq(_CR.validate(loaded["quests"], loaded["items"], loaded["npcs"]), [])


func test_get_quest_q001_objectives():
	var loaded := _load_seed()
	var quest = loaded["quests"]["q001"]
	assert_eq(quest.objectives.size(), 4)
	var types := []
	for objective in quest.objectives:
		types.append(objective["type"])
	assert_true(types.has("kill"))
	assert_true(types.has("collect"))
	assert_true(types.has("talk"))
	assert_true(types.has("reach"))


func test_reach_objective_has_coordinates():
	var loaded := _load_seed()
	var quest = loaded["quests"]["q001"]
	var reach_objective := {}
	for objective in quest.objectives:
		if objective["type"] == "reach":
			reach_objective = objective
			break
	assert_eq(reach_objective["x"], 42.0)
	assert_eq(reach_objective["y"], -13.0)
	assert_eq(reach_objective["radius"], 3.0)


func test_crypt_restless_dead_wired() -> void:
	# T-335: Father Osric's entry quest — investigate the porch, then thin the T-341 undead trash
	# packs (T-330's instance-scoped spawns, not open-world spawns.json). The boss-kill step
	# (mob_crypt_aldric/vharis/maldrath, the T-333 dungeon_schedule.json naming) is deferred until
	# T-332 lands real boss defs — wiring a kill objective at an unspawned mob would fail
	# validate_sources (T-073's "no ghost targets" rule), so it is intentionally NOT in this quest.
	var loaded := _load_seed()
	assert_true(loaded["quests"].has("q_crypt_restless_dead"), "crypt entry quest present")
	var quest = loaded["quests"]["q_crypt_restless_dead"]
	assert_eq(quest.giver_npc, "npc_village_parson")
	assert_eq(quest.turnin_npc, "npc_village_parson")
	assert_eq(quest.min_level, 12)
	var types: Array = quest.objectives.map(func(o): return o["type"])
	assert_eq(
		types, ["reach", "kill", "kill", "kill"], "investigate then thin the three undead packs"
	)
	var kill_targets: Array = []
	for objective in quest.objectives:
		if objective["type"] == "kill":
			kill_targets.append(objective["target"])
	assert_eq(
		kill_targets,
		["mob_skeletal_warrior", "mob_crypt_ghoul", "mob_restless_shade"],
		"the T-341 undead family, not phantom boss ids"
	)
	assert_true(quest.rewards["items"].size() >= 1, "grants a grave-goods reward")
	var npcs: Dictionary = loaded["npcs"]
	assert_true(
		npcs["npc_village_parson"].gives_quests.has("q_crypt_restless_dead"),
		"Father Osric offers the quest"
	)
	assert_eq(_CR.validate(loaded["quests"], loaded["items"], loaded["npcs"]), [])


func test_era1_capstone_chain_ramps_to_the_rift() -> void:
	# T-357: the L15-20 graduation arc. Five new quests chain crypt-clear -> rift crossing, all
	# given/turned-in by Father Osric, each gated a rung higher, and the last FEEDS the rift quest.
	var loaded := _load_seed()
	var quests: Dictionary = loaded["quests"]
	var chain := [
		"q_crypt_restless_dead",
		"q_hollowing_creep",
		"q_osric_registers",
		"q_ward_the_graves",
		"q_deep_vault_watch",
		"q_the_seal_sings",
		"q_rift_vault_counted",
	]
	for i in range(1, chain.size()):
		var q = quests.get(chain[i])
		assert_not_null(q, "%s present" % chain[i])
		if q == null:
			continue
		assert_eq(
			str(q.prerequisite_quest), chain[i - 1], "%s follows %s" % [chain[i], chain[i - 1]]
		)
	# The five capstone quests belong to the L15-20 band and ramp in level.
	var mins := {
		"q_hollowing_creep": 15,
		"q_osric_registers": 15,
		"q_ward_the_graves": 16,
		"q_deep_vault_watch": 17,
		"q_the_seal_sings": 18,
	}
	for qid: String in mins:
		assert_eq(int(quests[qid].min_level), mins[qid], "%s gated at L%d" % [qid, mins[qid]])
		assert_eq(quests[qid].giver_npc, "npc_village_parson", "%s given by Osric" % qid)
	# The crossing now sits at the cap edge, behind the whole arc.
	assert_eq(
		int(quests["q_rift_vault_counted"].min_level), 19, "the crossing is a near-cap capstone"
	)
	# Every capstone reward respects the §4.1 rare cap — no epics/legendaries in demo loot.
	var items: Dictionary = loaded["items"]
	var cap_rewards := [
		"itm_osric_ward_censer",
		"itm_gravewarden_hauberk",
		"itm_hollowing_ward_charm",
		"itm_deepvault_hood",
		"itm_riftward_blade",
	]
	const RARE_ATTACK_CAP := 19  # Gravetide, the shipped Era-1 top rare
	const RARE_ARMOR_CAP := 13  # Maldrath's Last Shroud
	for rid: String in cap_rewards:
		var it = items.get(rid)
		assert_not_null(it, "%s present" % rid)
		if it == null:
			continue
		assert_true(["uncommon", "rare"].has(it.rarity), "%s stays at/below rare" % rid)
		assert_true(
			int(it.stats.get("attack", 0)) <= RARE_ATTACK_CAP, "%s within rare attack cap" % rid
		)
		assert_true(
			int(it.stats.get("armor", 0)) <= RARE_ARMOR_CAP, "%s within rare armor cap" % rid
		)
	assert_eq(_CR.validate(loaded["quests"], loaded["items"], loaded["npcs"]), [])
	assert_eq(
		_CR.validate_sources(
			loaded["quests"], loaded["mobs"], loaded["items"], loaded["gather_nodes"]
		),
		[]
	)


func test_ashmoor_syndicate_arc_wired() -> void:
	# T-358: the L20-40 Era-2 street arc. Six quests chain off q_ashmoor_first_blood, each gated a
	# rung higher into the band, every kill target a spawned Syndicate mob, ~1.2k+ XP per turn-in.
	var loaded := _load_seed()
	var quests: Dictionary = loaded["quests"]
	var chain := [
		"q_ashmoor_first_blood",
		"q_ashmoor_street_tax",
		"q_ashmoor_numbers_racket",
		"q_ashmoor_protection_racket",
		"q_ashmoor_torpedo_run",
		"q_ashmoor_crooked_badge",
		"q_ashmoor_kingpin_reckoning",
	]
	var mins := [15, 20, 22, 25, 28, 32, 36]
	for i in range(1, chain.size()):
		var q = quests.get(chain[i])
		assert_not_null(q, "%s present" % chain[i])
		if q == null:
			continue
		assert_eq(
			str(q.prerequisite_quest), chain[i - 1], "%s follows %s" % [chain[i], chain[i - 1]]
		)
		assert_eq(int(q.min_level), mins[i], "%s gated at L%d" % [chain[i], mins[i]])
		assert_true(int(q.rewards.get("xp", 0)) >= 1200, "%s pays a band-tier reward" % chain[i])
	# Every kill target resolves to a real spawned Syndicate mob (no ghost objectives).
	assert_eq(
		_CR.validate_sources(
			loaded["quests"], loaded["mobs"], loaded["items"], loaded["gather_nodes"]
		),
		[]
	)


func test_crypt_undead_kill_targets_resolve_via_instance_spawns() -> void:
	# T-335: content_registry must see T-330's instance-scoped mobs (data/instances/hollowed_crypt.json)
	# as legitimate kill targets even though they never appear in the open-world mobs/spawns.json —
	# otherwise every crypt quest kill objective lint-fails validate_sources (T-073).
	var loaded := _load_seed()
	for mob_id in ["mob_skeletal_warrior", "mob_crypt_ghoul", "mob_restless_shade"]:
		assert_true(loaded["mobs"].has(mob_id), "%s resolves as a killable mob" % mob_id)
	assert_eq(
		_CR.validate_sources(
			loaded["quests"], loaded["mobs"], loaded["items"], loaded["gather_nodes"]
		),
		[]
	)


func test_validate_clean_seed():
	var loaded := _load_seed()
	assert_eq(_CR.validate(loaded["quests"], loaded["items"], loaded["npcs"]), [])


func test_dangling_giver_npc():
	var loaded := _load_seed()
	var quests: Dictionary = loaded["quests"].duplicate()
	var bad_quest = _copy_quest(quests["q001"])
	bad_quest.giver_npc = "npc_nobody"
	quests["q_bad_giver"] = bad_quest
	assert_true(_has_error(_validate_seed_with(quests, null, null), "npc_nobody"))


func test_unknown_objective_type():
	var loaded := _load_seed()
	var quests: Dictionary = loaded["quests"].duplicate()
	var bad_quest = _copy_quest(quests["q001"])
	bad_quest.objectives = [
		{"type": "steal", "target": "itm_wolf_pelt", "count": 1, "desc": "Steal"}
	]
	quests["q_bad_objective"] = bad_quest
	assert_true(_has_error(_validate_seed_with(quests, null, null), "steal"))


# T-426: the tutorial verbs validate — equip (real item ref) + use_ability (slug, not cross-checked).
func test_tutorial_objective_types_are_valid():
	var loaded := _load_seed()
	var quests: Dictionary = loaded["quests"].duplicate()
	var q = _copy_quest(quests["q001"])
	q.objectives = [
		{"type": "equip", "target": "itm_leather_cap", "count": 1, "desc": "Equip the cap"},
		{"type": "use_ability", "target": "heroic_strike", "count": 1, "desc": "Use Heroic Strike"},
	]
	quests["q_tutorial_verbs"] = q
	var errors := _validate_seed_with(quests, null, null)
	assert_false(_has_error(errors, "q_tutorial_verbs"), "tutorial verbs should lint clean")


# T-426 slice 4: the tactical interrupt verb is a valid objective type (target deferred like kill).
func test_interrupt_objective_type_is_valid():
	var loaded := _load_seed()
	var quests: Dictionary = loaded["quests"].duplicate()
	var q = _copy_quest(quests["q001"])
	q.objectives = [
		{"type": "interrupt", "target": "mob_training_effigy", "count": 1, "desc": "Break it"}
	]
	quests["q_interrupt_verb"] = q
	assert_false(
		_has_error(_validate_seed_with(quests, null, null), "q_interrupt_verb"),
		"interrupt verb should lint clean"
	)


func test_interrupt_target_without_spawned_mob_is_lint_error() -> void:
	var quests := _quest_fixture([{"type": "interrupt", "target": "mob_ghost", "count": 1}])
	var errors: Array = _CR.validate_sources(quests, _mobs_fixture(), {})
	assert_eq(errors.size(), 1)
	assert_string_contains(str(errors[0]), "interrupt target has no spawned mob")


func test_interrupt_wildcard_target_lints_clean() -> void:
	var quests := _quest_fixture([{"type": "interrupt", "target": "*", "count": 1}])
	var errors: Array = _CR.validate_sources(quests, _mobs_fixture(), {})
	assert_eq(errors.size(), 0, str(errors))


func test_equip_objective_unknown_item_errors():
	var loaded := _load_seed()
	var quests: Dictionary = loaded["quests"].duplicate()
	var q = _copy_quest(quests["q001"])
	q.objectives = [{"type": "equip", "target": "itm_nonexistent", "count": 1, "desc": "Equip"}]
	quests["q_bad_equip"] = q
	assert_true(_has_error(_validate_seed_with(quests, null, null), "itm_nonexistent"))


func test_duplicate_item_id():
	var loaded := _load_seed()
	var items: Dictionary = loaded["items"].duplicate()
	items["itm_wolf_pelt_duplicate"] = items["itm_wolf_pelt"]
	assert_true(_has_error(_validate_seed_with(null, items, null), "duplicate"))


func test_unknown_key_in_item():
	var loaded := _load_seed()
	var items: Dictionary = loaded["items"].duplicate()
	items["itm_bad_rarity"] = {
		"id": "itm_bad_rarity",
		"name": "Bad Rarity",
		"slot": "none",
		"stackable": true,
		"max_stack": 10,
		"stats": {},
		"vendor_value": 1,
		"description": "Has an unknown key.",
		"flavor": "smoky"  # T-230 made 'rarity' a KNOWN key; this test needs a real stranger
	}
	assert_true(_has_error(_validate_seed_with(null, items, null), "flavor"))


func test_stackable_false_max_stack_gt1():
	var loaded := _load_seed()
	var items: Dictionary = loaded["items"].duplicate()
	var bad_item = _copy_item(items["itm_wolf_pelt"])
	bad_item.id = "itm_bad_stack"
	bad_item.stackable = false
	bad_item.max_stack = 5
	items["itm_bad_stack"] = bad_item
	assert_true(_has_error(_validate_seed_with(null, items, null), "max_stack"))


func test_self_referential_prerequisite():
	var loaded := _load_seed()
	var quests: Dictionary = loaded["quests"].duplicate()
	var bad_quest = _copy_quest(quests["q001"])
	bad_quest.prerequisite_quest = "q001"
	quests["q001"] = bad_quest
	assert_true(_has_error(_validate_seed_with(quests, null, null), "self-referential"))


func _copy_quest(quest):
	var copy = quest.get_script().new()
	for key in [
		"id", "title", "giver_npc", "turnin_npc", "min_level", "prerequisite_quest", "description"
	]:
		copy.set(key, quest.get(key))
	copy.objectives = quest.objectives.duplicate(true)
	copy.rewards = quest.rewards.duplicate(true)
	copy._source_keys = quest._source_keys.duplicate()
	return copy


func _copy_item(item):
	var copy = item.get_script().new()
	for key in [
		"id", "name", "slot", "stackable", "max_stack", "stats", "vendor_value", "description"
	]:
		copy.set(key, item.get(key))
	copy.stats = item.stats.duplicate(true)
	copy._source_keys = item._source_keys.duplicate()
	return copy


# ---- T-073: source validation — kill targets must spawn, collect targets must drop ----


func _mobs_fixture() -> Dictionary:
	return {
		"mob_wolf": {"mob_id": "mob_wolf", "loot": [{"item_id": "itm_wolf_pelt", "chance": 1.0}]}
	}


func _quest_fixture(objectives: Array) -> Dictionary:
	return {"q_test": {"id": "q_test", "objectives": objectives}}


func test_kill_target_without_spawned_mob_is_lint_error() -> void:
	var quests := _quest_fixture([{"type": "kill", "target": "mob_ghost", "count": 1}])
	var errors: Array = _CR.validate_sources(quests, _mobs_fixture(), {})
	assert_eq(errors.size(), 1)
	assert_string_contains(str(errors[0]), "kill target has no spawned mob")


func test_collect_target_without_producer_is_lint_error() -> void:
	var quests := _quest_fixture([{"type": "collect", "target": "itm_unicorn_horn", "count": 1}])
	var errors: Array = _CR.validate_sources(quests, _mobs_fixture(), {})
	assert_eq(errors.size(), 1)
	assert_string_contains(str(errors[0]), "collect target has no producer")


func test_sourced_kill_and_collect_lint_clean() -> void:
	var quests := _quest_fixture(
		[
			{"type": "kill", "target": "mob_wolf", "count": 8},
			{"type": "collect", "target": "itm_wolf_pelt", "count": 5},
		]
	)
	var errors: Array = _CR.validate_sources(quests, _mobs_fixture(), {})
	assert_eq(errors.size(), 0, str(errors))


func test_loot_naming_unknown_item_is_lint_error() -> void:
	var items := {"itm_real": {"id": "itm_real"}}
	var mobs := {"mob_x": {"mob_id": "mob_x", "loot": [{"item_id": "itm_fake", "chance": 1.0}]}}
	var errors: Array = _CR.validate_sources({}, mobs, items)
	assert_eq(errors.size(), 1)
	assert_string_contains(str(errors[0]), "unknown item")


func test_item_rarity_loads_and_validates() -> void:
	# T-230: every item carries a valid tier; bad tiers are load errors (fail-loud).
	var loaded := _load_seed()
	var items: Dictionary = loaded["items"]
	for id in items:
		assert_true(
			["junk", "common", "uncommon", "rare", "epic", "legendary"].has(items[id].rarity),
			"%s has a valid rarity" % id
		)
	assert_eq(items["itm_iron_sword"].rarity, "uncommon")
	assert_eq(items["itm_vault_voucher"].rarity, "rare")
	assert_eq(items["itm_wolf_pelt"].rarity, "common")
	var bad = {"id": "itm_bad", "name": "Bad", "slot": "", "rarity": "mythic"}
	var errors := _CR.validate({}, {"itm_bad": _CR._item(bad)}, {})
	var hit := false
	for e in errors:
		if "invalid rarity" in str(e):
			hit = true
	assert_true(hit, "unknown tier rejected")


func test_enrich_inventory_carries_rarity() -> void:
	var loaded := _load_seed()
	var slots := [
		{"slot_type": "bag", "slot_index": 0, "item_id": "itm_iron_sword", "item_count": 1}
	]
	var out := _CQ.enrich_inventory(slots, loaded["items"])
	assert_eq(str((out[0] as Dictionary)["rarity"]), "uncommon")


# ---- T-685: the dead-drop oracle — a rare gather proc must have a real reagent use ----


# Every reagent minted by a gather `bonus_find` proc must be consumed by at least one recipe input
# (or a quest collect objective) — no rare gather proc may ship as pure vendor-trash while its own
# flavor text promises a crafting use. This is the invariant T-677's faucet left unguarded: every
# existing oracle read "sellable" (vendor_value) as "used", so a rare proc with no recipe slipped
# past silently (T-685). Data-driven over the LIVE bonus_find table, so a future rare proc shipped
# without a sink fails here loudly.
func test_every_rare_gather_proc_has_a_reagent_use() -> void:
	var loaded := _load_seed()
	var used := _consuming_item_ids(loaded)
	var checked := 0
	for node_id in loaded["gather_nodes"]:
		var bonus: Dictionary = loaded["gather_nodes"][node_id].get("bonus_find", {})
		if bonus.is_empty():
			continue
		var item_id := str(bonus.get("item_id", ""))
		checked += 1
		assert_true(
			used.has(item_id),
			(
				"gather node %s mints rare proc %s with no recipe/quest that consumes it (dead drop)"
				% [node_id, item_id]
			)
		)
	assert_gt(checked, 0, "the bonus_find table is non-empty (the guard is actually exercised)")


# The set of every item id that has a real downstream USE beyond vendoring: consumed by a recipe
# input, or required by a quest collect objective. Reads recipes.json directly — it is a world-side
# registry loaded by craft_service (T-414), not part of content_registry.load_all.
func _consuming_item_ids(loaded: Dictionary) -> Dictionary:
	var used: Dictionary = {}
	for recipe: Dictionary in _load_recipes():
		for input: Dictionary in recipe.get("inputs", []):
			used[str(input.get("item", ""))] = true
	for quest_id in loaded["quests"]:
		var quest = loaded["quests"][quest_id]
		for objective in quest.objectives:
			if str(objective.get("type", "")) == "collect":
				used[str(objective.get("target", ""))] = true
	return used


func _load_recipes() -> Array:
	var path := _data_path().path_join("recipes").path_join("recipes.json")
	var file := FileAccess.open(path, FileAccess.READ)
	assert_not_null(file, "recipes.json opens at %s" % path)
	if file == null:
		return []
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	assert_true(
		parsed is Dictionary and parsed.get("recipes", null) is Array, "recipes.json has a shape"
	)
	return parsed["recipes"] if parsed is Dictionary else []
