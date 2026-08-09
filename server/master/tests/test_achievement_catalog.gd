extends GutTest

# T-676: the achievement CONTENT catalog + the criteria events it references. Guards the exact
# stub-vs-engine gap the ticket closes: a JSON row may only reference an event the engine advances
# AND the server actually emits; every reward passes the T-482 power-free charter; meta-achievements
# resolve once, only when their members are all complete; and the 1->cap Arc clock is never empty.

const CharacterManager = preload("res://scripts/character_manager.gd")
const AchievementRegistry = preload("res://scripts/achievement_registry.gd")
const AchievementProgress = preload("res://scripts/achievement_progress.gd")
const AchievementStore = preload("res://scripts/achievement_store.gd")
const AccountMastery = preload("res://scripts/account_mastery.gd")

# The purchasable-cosmetic namespaces (wardrobe store rows + PvP prestige skins). An EARNED
# achievement cosmetic must live OUTSIDE these, so the store can never sell status you have to play
# for (the T-482 "earned marquee unreachable by purchase" rule, checked from the reward side).
const _STORE_PREFIXES := ["cos_", "skin_"]
const _POWER_FIELDS := ["stats", "attack", "armor", "damage", "power", "bonuses", "effects", "hp"]
const _ARC_FLOOR := 8  # the ticket's ~8-12 incomplete-achievements floor


func before_each() -> void:
	CharacterManager._test_skip_db = true
	CharacterManager.reset_for_test()
	AchievementStore.reset_for_test()
	AccountMastery.reset_for_test()
	AchievementRegistry._reload_for_test()  # undo any _override_for_test — read the SHIPPED file


func _defs() -> Array:
	var defs := AchievementRegistry.defs()
	assert_gt(defs.size(), 20, "the catalog is a real long-tail ladder, not the 9-row stub")
	return defs


# ---- (a) catalog-integrity: every criteria.event is engine-known AND server-emitted ----------


func test_every_criteria_event_is_supported_by_the_engine() -> void:
	for def: Dictionary in _defs():
		var event := str((def.get("criteria", {}) as Dictionary).get("event", ""))
		assert_true(
			event in AchievementProgress.SUPPORTED_EVENTS,
			"%s references unknown criteria event '%s'" % [str(def.get("id", "")), event]
		)


func test_every_external_event_has_a_live_server_emit_site() -> void:
	# The regression guard: an external criteria event must actually be observed somewhere in the
	# master scripts (a `.observe(_, "<event>", ...)` call). A row referencing a hook that was never
	# wired fails HERE, loudly — exactly the stub-vs-engine gap this ticket exists to close.
	var sources := _read_all_scripts()
	for event: String in AchievementProgress.SUPPORTED_EVENTS:
		if event in AchievementProgress.DERIVED_EVENTS:
			continue  # "achievement"/"group" are engine-derived (written by the completion loop)
		var wired := false
		for text: String in sources:
			if text.contains(".observe(") and text.contains(', "%s"' % event):
				wired = true
				break
		assert_true(
			wired, "external event '%s' is referenced but never emitted by the server" % event
		)


func _read_all_scripts() -> Array:
	var out: Array = []
	var dir := DirAccess.open("res://scripts")
	assert_not_null(dir, "scripts dir opens")
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.ends_with(".gd"):
			var f := FileAccess.open("res://scripts/" + name, FileAccess.READ)
			if f != null:
				out.append(f.get_as_text())
		name = dir.get_next()
	dir.list_dir_end()
	return out


# ---- (b) no dead Arc clock: >= K reachable at every checkpoint across the 1->cap arc ----------


func test_arc_clock_is_never_empty_across_the_level_arc() -> void:
	var defs := _defs()
	for probe: Dictionary in _arc_probes():
		var reachable := 0
		for def: Dictionary in defs:
			# Not yet complete == reachable: achievements are monotonic and never lock out, so an
			# unearned def is always still "the thing you can work toward".
			if AchievementProgress.fraction(def.get("criteria", {}), probe["counters"]) < 1.0:
				reachable += 1
		assert_gte(
			reachable,
			_ARC_FLOOR,
			(
				"%s: only %d achievements reachable (Arc clock floor is %d)"
				% [str(probe["label"]), reachable, _ARC_FLOOR]
			)
		)


# Representative "did the obvious content for my level" counter states — NOT completionist runs.
func _arc_probes() -> Array:
	return [
		{"label": "L5", "counters": {"level": 5, "kill:*": 12, "quest:*": 2, "discovery:*": 1}},
		{
			"label": "L15",
			"counters":
			{
				"level": 15,
				"kill:*": 60,
				"quest:*": 12,
				"discovery:*": 3,
				"discovery_zone:era_1_hamlet": 2,
				"gather:*": 30,
				"craft:*": 5,
				"recipe:*": 2,
				"dungeon_boss:*": 1,
			}
		},
		{
			"label": "L25",
			"counters":
			{
				"level": 25,
				"kill:*": 300,
				"quest:*": 26,
				"discovery:*": 6,
				"gather:*": 120,
				"craft:*": 30,
				"recipe:*": 5,
				"dungeon_boss:*": 2,
				"pvp_win:*": 3,
				"pvp_win:duel": 1,
				"pvp_rating": 1450,
			}
		},
		{
			"label": "cap",
			"counters":
			{
				"level": 60,
				"kill:*": 600,
				"quest:*": 40,
				"discovery:*": 9,
				"gather:*": 200,
				"craft:*": 45,
				"recipe:*": 11,
				"dungeon_boss:*": 3,
				"raid_clear:*": 2,
				"pvp_win:*": 12,
				"pvp_win:duel": 1,
				"pvp_win:bg": 1,
				"pvp_rating": 1650,
			}
		},
	]


# ---- (c) meta-achievements resolve once, only when every member completes --------------------


func test_group_meta_resolves_only_when_all_members_complete_no_double_credit() -> void:
	var defs := [
		{"id": "m_a", "groups": ["z"], "criteria": {"event": "kill", "key": "*", "count": 1}},
		{"id": "m_b", "groups": ["z"], "criteria": {"event": "quest", "key": "*", "count": 1}},
		{"id": "meta_z", "meta": true, "criteria": {"event": "group", "key": "z", "count": 2}},
	]
	var state := {"counters": {}, "earned": []}
	# First member completes — the meta must NOT fire yet (one member short).
	var r1 := AchievementProgress.apply(defs, state, "kill", "wolf")
	assert_true("m_a" in r1["newly_earned"], "first member earns")
	assert_false("meta_z" in r1["newly_earned"], "meta holds while a member is missing")
	# Second (last) member completes — the meta resolves in the SAME observe (fixed-point sweep).
	var r2 := AchievementProgress.apply(
		defs, {"counters": r1["counters"], "earned": r1["earned"]}, "quest", "q1"
	)
	assert_true("m_b" in r2["newly_earned"], "last member earns")
	assert_true("meta_z" in r2["newly_earned"], "meta resolves once every member is complete")
	# A further observe never re-earns anything (no double-credit).
	var r3 := AchievementProgress.apply(
		defs, {"counters": r2["counters"], "earned": r2["earned"]}, "kill", "rat"
	)
	assert_eq(r3["newly_earned"].size(), 0, "nothing double-credits after the meta resolved")


func test_account_ladder_meta_counts_only_non_meta_achievements() -> void:
	var defs := [
		{"id": "a", "criteria": {"event": "kill", "key": "*", "count": 1}},
		{"id": "b", "criteria": {"event": "quest", "key": "*", "count": 1}},
		{
			"id": "ladder",
			"meta": true,
			"criteria": {"event": "achievement", "key": "*", "count": 2}
		},
	]
	var s1 := AchievementProgress.apply(defs, {"counters": {}, "earned": []}, "kill", "x")
	assert_false("ladder" in s1["newly_earned"], "ladder holds at 1 real achievement")
	var s2 := AchievementProgress.apply(
		defs, {"counters": s1["counters"], "earned": s1["earned"]}, "quest", "q"
	)
	assert_true("ladder" in s2["newly_earned"], "ladder resolves at 2 real achievements")
	assert_eq(int(s2["counters"]["achievement:*"]), 2, "only the two non-meta earns are counted")


# ---- (d) T-482 charter: rewards are power-free and store-unreachable --------------------------


func test_every_reward_passes_the_cosmetic_charter() -> void:
	for def: Dictionary in _defs():
		var reward: Dictionary = def.get("reward", {})
		var aid := str(def.get("id", ""))
		for key: Variant in reward:
			assert_true(
				str(key) in ["title", "coin", "cosmetic"],
				"%s reward carries non-horizontal key '%s'" % [aid, str(key)]
			)
			assert_false(str(key) in _POWER_FIELDS, "%s reward carries a power field" % aid)
		assert_gte(int(reward.get("coin", 0)), 0, "%s coin reward is never negative" % aid)
		if reward.has("cosmetic"):
			var cid := str(reward["cosmetic"])
			for prefix: String in _STORE_PREFIXES:
				assert_false(
					cid.begins_with(prefix),
					"%s earns store-namespace cosmetic '%s' (must be earn-only)" % [aid, cid]
				)


# ---- T-395 feed: an achievement completion grants account-mastery XP -------------------------


func test_completion_feeds_the_account_mastery_floor() -> void:
	CharacterManager.ensure_character("hero")
	var cid := int(CharacterManager.get_character("hero")["id"])
	var subject := AccountMastery.subject_for("hero", cid)
	assert_eq(int(AccountMastery.progress(subject)["xp"]), 0, "no mastery before any achievement")
	# first_blood clears on the first kill (shipped catalog).
	var earned: Array = AchievementStore.observe(cid, "kill", "wolf")["newly_earned"]
	assert_gt(earned.size(), 0, "a real achievement earned")
	assert_gt(
		int(AccountMastery.progress(subject)["xp"]),
		0,
		"completing an achievement fed the T-395 mastery floor",
	)
