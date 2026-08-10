extends GutTest

const DungeonLoot = preload("res://scripts/combat/dungeon_loot.gd")
const ContentRegistry = preload("res://scripts/content/content_registry.gd")
const WorldRpc = preload("res://scripts/world_rpc.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")

const TOKEN_A := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0"  # gitleaks:allow
const TOKEN_B := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0"  # gitleaks:allow

# T-473: the Era-1 raid tier bosses (Vault of the First Hollowing).
const _VAULT_BOSSES := ["mob_vault_sentinel", "mob_vault_dirgemother", "mob_vault_hollow_king"]

# The T-353 epic index cap: era_gear.RARITY_INDEX epic 150 over rare 100 — an Era-1 epic may sit
# at most 1.5x the rare ceiling of its slot (era_gear.gd is master-side; the ratio is mirrored
# here because cross-project preloads don't resolve — keep in sync with RARITY_INDEX).
const _EPIC_OVER_RARE_CAP := 1.5


class FakeMaster:
	var calls: Array = []

	func call_master(method: String, params: Dictionary) -> Dictionary:
		calls.append({"method": method, "params": params})
		await (Engine.get_main_loop() as SceneTree).process_frame
		return {"ok": true, "credited": []}


func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


func test_real_schedule_has_guaranteed_green_and_named_blue_pool_per_boss() -> void:
	var schedule := DungeonLoot.load_schedule()
	var items: Dictionary = ContentRegistry.load_all("res://data")["items"]
	for boss_id in ["mob_crypt_aldric", "mob_crypt_vharis", "mob_crypt_maldrath"]:
		var boss: Dictionary = schedule.get(boss_id, {})
		assert_false(boss.is_empty(), "%s has a dungeon schedule" % boss_id)
		assert_gte(boss.get("guaranteed_green", []).size(), 1)
		assert_gte(boss.get("named_blue_pool", []).size(), 2)
		assert_between(float(boss.get("blue_chance", 0.0)), 0.01, 0.50)
		for green_id in boss["guaranteed_green"]:
			assert_eq(items[str(green_id)].rarity, "uncommon")
		for blue_id in boss["named_blue_pool"]:
			var item = items[str(blue_id)]
			assert_eq(item.rarity, "rare", "named blue uses the blue rarity-color tier")
			assert_ne(item.description, "", "named blue has tooltip copy")


func test_roll_always_grants_green_and_seeded_blue_rate_matches_authored_odds() -> void:
	var schedule := DungeonLoot.load_schedule()
	var boss: Dictionary = schedule["mob_crypt_aldric"]
	var blue_count := 0
	var attempts := 4000
	for i in range(attempts):
		var result := DungeonLoot.roll_boss(boss, _rng(9000 + i))
		assert_gte(result["guaranteed_items"].size(), 1)
		if str(result.get("blue_item", "")) != "":
			blue_count += 1
	var expected := int(attempts * float(boss["blue_chance"]))
	assert_between(blue_count, expected - 160, expected + 160)


func test_dungeon_loot_grants_to_every_party_eligible_recipient() -> void:
	var master := FakeMaster.new()
	var rpc := WorldRpc.new()
	assert_eq(rpc.setup(master, func(_pid, _data): pass), "")
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(10, TOKEN_A, "alice", Vector3.ZERO)
	PlayerSessions.add_player(11, TOKEN_B, "bob", Vector3.ZERO)
	var rng := _rng(333)
	rpc.on_dungeon_loot([10, 11], "mob_crypt_aldric", rng)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(master.calls.size(), 2)
	assert_eq(master.calls[0]["method"], "grant_dungeon_loot")
	assert_eq(master.calls[1]["method"], "grant_dungeon_loot")
	var users := [master.calls[0]["params"]["username"], master.calls[1]["params"]["username"]]
	assert_eq(users, ["alice", "bob"])


# ---- T-473: the Era-1 raid tier (Vault of the First Hollowing) + round-robin distribution ----


func test_vault_schedule_is_weekly_cadence_epic_tier() -> void:
	var schedule := DungeonLoot.load_schedule()
	var items: Dictionary = ContentRegistry.load_all("res://data")["items"]
	for boss_id in _VAULT_BOSSES:
		var boss: Dictionary = schedule.get(boss_id, {})
		assert_false(boss.is_empty(), "%s has a raid schedule" % boss_id)
		assert_eq(str(boss.get("cadence", "")), "weekly", "%s re-locks weekly" % boss_id)
		assert_gte(boss.get("guaranteed_green", []).size(), 1)
		assert_gte(boss.get("named_blue_pool", []).size(), 2)
		assert_between(float(boss.get("blue_chance", 0.0)), 0.3, 0.5)
		for green_id in boss["guaranteed_green"]:
			assert_eq(items[str(green_id)].rarity, "uncommon")
		for epic_id in boss["named_blue_pool"]:
			var item = items[str(epic_id)]
			assert_eq(item.rarity, "epic", "%s: the raid tier is the epic tier" % epic_id)
			assert_ne(item.description, "", "%s has tooltip copy" % epic_id)
	assert_true(
		(schedule["mob_vault_hollow_king"]["named_blue_pool"] as Array).has(
			"itm_maldrath_hollow_crown"
		),
		"the orphaned T-353 relic is homed on the final boss"
	)
	for boss_id in ["mob_crypt_aldric", "mob_crypt_vharis", "mob_crypt_maldrath"]:
		assert_eq(str(schedule[boss_id].get("cadence", "daily")), "daily", "5-man stays daily")


func test_raid_epics_sit_above_crypt_rare_ceiling_under_the_carry_cap() -> void:
	var schedule := DungeonLoot.load_schedule()
	var items: Dictionary = ContentRegistry.load_all("res://data")["items"]
	# Per-slot RARE ceilings across the whole shipped item set (computed, not hardcoded).
	var rare_ceiling := {}
	for item_id in items:
		var it = items[item_id]
		if it.rarity != "rare":
			continue
		var v := _power(it.stats)
		rare_ceiling[it.slot] = maxf(float(rare_ceiling.get(it.slot, 0.0)), v)
	for boss_id in _VAULT_BOSSES:
		for epic_id in schedule[boss_id]["named_blue_pool"]:
			var it = items[str(epic_id)]
			var ceiling := float(rare_ceiling.get(it.slot, 0.0))
			assert_gt(ceiling, 0.0, "%s: a rare comparator exists for slot %s" % [epic_id, it.slot])
			var v := _power(it.stats)
			assert_gt(v, ceiling, "%s beats the Era-1 rare %s ceiling" % [epic_id, it.slot])
			assert_lte(
				v,
				ceiling * _EPIC_OVER_RARE_CAP,
				"%s stays under the T-353 epic index cap (150 vs rare 100)" % epic_id
			)


func _power(stats: Dictionary) -> float:
	return maxf(float(stats.get("attack", 0)), float(stats.get("armor", 0)))


func _raid_party(members: Array) -> Dictionary:
	return {"members": members.duplicate(), "loot_rule": "round_robin", "loot_cursor": 0}


func test_round_robin_rotates_the_gated_drop_and_greens_land_on_everyone() -> void:
	var schedule := {
		"cadence": "weekly",
		"guaranteed_green": ["itm_green"],
		"blue_chance": 1.0,
		"named_blue_pool": ["itm_epic"],
	}
	var party := _raid_party([1, 2, 3])
	var winners: Array = []
	for kill in range(6):
		var shares := DungeonLoot.distribute(schedule, [1, 2, 3], party, _rng(500 + kill))
		assert_eq(shares.size(), 3, "every recipient gets a share row")
		var kill_winners: Array = []
		for share: Dictionary in shares:
			var rolled: Dictionary = share["rolled"]
			assert_eq((rolled["guaranteed_items"] as Array).size(), 1, "greens are ungated")
			assert_eq(str(rolled["cadence"]), "weekly")
			if str(rolled["blue_item"]) != "":
				kill_winners.append(int(share["peer"]))
		assert_eq(kill_winners.size(), 1, "the gated drop rolls ONCE per kill for the raid")
		winners.append(kill_winners[0])
	assert_eq(winners, [1, 2, 3, 1, 2, 3], "rotation follows members order and wraps")
	assert_eq(int(party["loot_cursor"]), 6, "the cursor lives on the party record across kills")


func test_round_robin_skips_ineligible_members_and_a_miss_holds_the_cursor() -> void:
	var schedule := {
		"guaranteed_green": ["itm_green"], "blue_chance": 1.0, "named_blue_pool": ["itm_epic"]
	}
	var party := _raid_party([1, 2, 3, 4])
	# Peers 2 and 4 are not kill-eligible (dead/out of range) — rotation runs over 1 and 3 only.
	var shares := DungeonLoot.distribute(schedule, [1, 3], party, _rng(42))
	assert_eq(shares.size(), 2)
	var no_drop := {
		"guaranteed_green": ["itm_green"], "blue_chance": 0.0, "named_blue_pool": ["itm_epic"]
	}
	var cursor_before := int(party["loot_cursor"])
	for share: Dictionary in DungeonLoot.distribute(no_drop, [1, 3], party, _rng(43)):
		assert_eq(str((share["rolled"] as Dictionary)["blue_item"]), "", "no drop on a miss")
	assert_eq(int(party["loot_cursor"]), cursor_before, "a miss never advances the rotation")


func test_plain_party_keeps_independent_rolls() -> void:
	var schedule := {
		"guaranteed_green": ["itm_green"], "blue_chance": 1.0, "named_blue_pool": ["itm_epic"]
	}
	# No loot_rule on the record (a plain T-280 party) -> the T-333 behaviour: everyone rolls.
	var shares := DungeonLoot.distribute(schedule, [1, 2, 3], {"members": [1, 2, 3]}, _rng(7))
	for share: Dictionary in shares:
		var rolled: Dictionary = share["rolled"]
		assert_eq(
			str(rolled["blue_item"]), "itm_epic", "chance 1.0 -> every member's own roll hits"
		)
		assert_eq(str(rolled["cadence"]), "daily", "absent cadence defaults to daily")
