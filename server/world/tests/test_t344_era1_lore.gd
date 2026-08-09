extends GutTest

# T-344: Era-1 lore seeding (era-direction.md §7) — Hollow King patient-zero line, the sealed
# Vault era-rift (data-only + a decorative non-interactive prop), Father Osric's foreshadowing.
# Pure text/data on top of shipped T-317/T-330/T-332/T-335 content; asserts no combat/stat drift.

const _CR = preload("res://scripts/content/content_registry.gd")


func _data_path() -> String:
	return ProjectSettings.globalize_path("res://data")


func _load_seed() -> Dictionary:
	return _CR.load_all(_data_path())


func test_maldrath_lore_is_patient_zero_and_stats_unchanged() -> void:
	var loaded := _load_seed()
	assert_true(loaded["mobs"].has("mob_crypt_maldrath"), "Maldrath is a spawnable/instance mob")
	var maldrath: Dictionary = loaded["mobs"]["mob_crypt_maldrath"]
	var lore := str(maldrath.get("lore", ""))
	assert_true(lore.find("patient zero") >= 0, "lore names him patient zero")
	assert_true(lore.find("Hollowing") >= 0, "lore ties him to the working-name meta-evil")
	# T-332's stat block, byte-identical (no combat drift from a text-only ticket).
	assert_eq(maldrath.get("elite_hp_mult"), 6.0)
	assert_eq(maldrath.get("elite_damage_mult"), 2.75)
	assert_eq(maldrath.get("enrage_threshold"), 0.5)
	assert_eq(maldrath.get("enrage_mult"), 1.4)
	assert_eq(maldrath.get("boss_mechanic"), "phase_summon")
	assert_eq(maldrath.get("phase2_threshold"), 0.5)
	assert_eq(maldrath.get("phase2_cadence"), 200)
	assert_eq(maldrath.get("max_adds"), 3)
	assert_eq(maldrath.get("str"), 46)
	assert_eq(maldrath.get("base_damage"), 18)
	assert_eq(maldrath.get("loot"), [])


func test_vault_era_rift_is_data_only_foreshadowing() -> void:
	var errors: Array = []
	var parsed = _CR._parse(_data_path().path_join("dungeons/hollowed_crypt_layout.json"), errors)
	assert_eq(errors, [])
	assert_true(parsed is Dictionary and parsed.has("era_rift"), "layout carries the era-rift seed")
	var rift: Dictionary = parsed["era_rift"]
	assert_eq(rift.get("chamber"), "the_vault")
	assert_true(str(rift.get("description", "")).find("hundred years too old") >= 0)
	# No teleport/interaction keys — Era 1 is pure foreshadowing (era-direction.md §7.2).
	assert_false(rift.has("teleport"))
	assert_false(rift.has("target_region"))


func test_osric_foreshadowing_dialogue_and_existing_flows_intact() -> void:
	var loaded := _load_seed()
	var npcs: Dictionary = loaded["npcs"]
	assert_true(npcs.has("npc_village_parson"))
	var osric = npcs["npc_village_parson"]
	assert_true(osric.talk_text.find("registers") >= 0, "reads the burial registers")
	assert_true(osric.talk_text.find("reaching forward through the graves") >= 0, "the unease line")
	# T-317/T-335: existing greeting + quest wiring must survive the dialogue extension.
	assert_true(osric.talk_text.begins_with("Rest a moment, traveler."))
	assert_true(osric.gives_quests.has("q_crypt_restless_dead"))
	var quest = loaded["quests"]["q_crypt_restless_dead"]
	assert_eq(quest.giver_npc, "npc_village_parson")
	assert_eq(quest.turnin_npc, "npc_village_parson")
	assert_eq(_CR.validate(loaded["quests"], loaded["items"], loaded["npcs"]), [])
