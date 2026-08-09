extends GutTest

# T-679: guild COLLECTIVE achievements — the server-authoritative trophy wall + the guild-earned
# cosmetic identity whose eligibility follows membership. Runs against the test-mode fakes (no live
# Postgres). Covers every ticket DoD assertion:
#   - a milestone is credited to the GUILD, not double-counted per member, and fires exactly once;
#   - a member joining a guild that ALREADY earned a milestone does NOT re-fire it;
#   - the guild-earned cosmetic is wearable while in the guild and drops out of eligibility on
#     leave/kick (identity is the guild's) WITHOUT destroying an individually-owned unlock;
#   - the whole surface is server-observed (no client verb credits a guild achievement).

const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const GuildStore = preload("res://scripts/guild_store.gd")
const GuildAchievementStore = preload("res://scripts/guild_achievement_store.gd")
const GuildAchievementRegistry = preload("res://scripts/guild_achievement_registry.gd")
const WardrobeOps = preload("res://scripts/wardrobe_ops.gd")

# A tiny in-memory catalog: a kill milestone that grants a guild cosmetic on the FIRST credited
# kill, so eligibility/earn behaviour is exercised without looping to a shipped 500-kill threshold.
const _TEST_DEFS := [
	{
		"id": "g_first_blood",
		"name": "Guild First Blood",
		"criteria": {"event": "guild_kill", "key": "*", "count": 1},
		"reward": {"cosmetic": "guild_tabard_vanguard"}
	},
	{
		"id": "g_warhost",
		"name": "Guild Warhost",
		"criteria": {"event": "guild_kill", "key": "*", "count": 3},
		"reward": {}
	},
]


func before_each() -> void:
	CharacterManager._test_skip_db = true
	CharacterManager.reset_for_test()
	GuildStore.reset_for_test()
	GuildAchievementStore.reset_for_test()
	WardrobeOps.reset_for_test()
	GuildAchievementRegistry._override_for_test(_TEST_DEFS)


func after_each() -> void:
	GuildAchievementRegistry._reload_for_test()


func _mk(username: String, coins: int = 5000) -> int:
	CharacterManager.ensure_character(username)
	var cid := int(CharacterManager.get_character(username)["id"])
	ServicesStore.adjust_coins(cid, coins - ServicesStore.get_coins(cid))
	return cid


# alice founds a guild, invites bob, bob accepts -> returns [gid, alice_cid, bob_cid].
func _guild_of_two() -> Array:
	var acid := _mk("alice")
	var bcid := _mk("bob")
	var created := GuildStore.op({"username": "alice", "action": "create", "name": "Vanguard"})
	var gid := int(created["guild_id"])
	GuildStore.op({"username": "alice", "action": "invite", "target_name": "bob"})
	GuildStore.op({"username": "bob", "action": "accept"})
	return [gid, acid, bcid]


# ---- credited to the guild, once, not per-member --------------------------------


func test_milestone_credits_the_guild_and_fires_once() -> void:
	var g := _guild_of_two()
	var gid: int = g[0]
	var first := GuildAchievementStore.observe(gid, "guild_kill", "wolf")
	assert_eq(first["newly_earned"].size(), 1, "the first credited kill earns the guild milestone")
	assert_eq(str(first["newly_earned"][0]["id"]), "g_first_blood")
	# A further guild kill never re-earns the same milestone (once-only guard).
	var again := GuildAchievementStore.observe(gid, "guild_kill", "rat")
	assert_false(
		"g_first_blood" in _ids(again["newly_earned"]), "an earned guild milestone never re-fires"
	)


func test_roster_total_aggregates_not_double_counted() -> void:
	var g := _guild_of_two()
	var gid: int = g[0]
	# Three member kills -> guild_kill:* == 3 (a running roster total, one increment per event).
	GuildAchievementStore.observe(gid, "guild_kill", "a")
	GuildAchievementStore.observe(gid, "guild_kill", "b")
	var third := GuildAchievementStore.observe(gid, "guild_kill", "c")
	assert_true("g_warhost" in _ids(third["newly_earned"]), "the 3-kill roster milestone resolves")
	var listed := GuildAchievementStore.list(gid)
	assert_eq(_fraction(listed, "g_warhost"), 1.0, "warhost complete")


func test_a_joiner_does_not_refire_an_already_earned_milestone() -> void:
	# alice solos the guild and earns the milestone BEFORE bob exists.
	var acid := _mk("alice")
	var created := GuildStore.op({"username": "alice", "action": "create", "name": "Vanguard"})
	var gid := int(created["guild_id"])
	assert_eq(acid, acid)  # (silence unused warning; acid documents alice's membership)
	GuildAchievementStore.observe(gid, "guild_kill", "wolf")
	assert_true(_earned(gid, "g_first_blood"), "guild earned the milestone while solo")
	# bob joins the guild that already earned it, then contributes a kill.
	_mk("bob")
	GuildStore.op({"username": "alice", "action": "invite", "target_name": "bob"})
	GuildStore.op({"username": "bob", "action": "accept"})
	var after_join := GuildAchievementStore.observe(gid, "guild_kill", "boar")
	assert_false(
		"g_first_blood" in _ids(after_join["newly_earned"]),
		"joining a guild that already earned a milestone never re-fires it",
	)


# ---- guild-earned cosmetic: eligibility follows membership -----------------------


func test_guild_cosmetic_is_wearable_in_guild_and_lost_on_leave_keeping_own_items() -> void:
	var g := _guild_of_two()
	var gid: int = g[0]
	var bcid: int = g[2]
	# bob owns an individually-bought look BEFORE the guild earns anything.
	WardrobeOps.grant_unlock(bcid, "cos_gilded_blade", "store")
	GuildAchievementStore.observe(gid, "guild_kill", "wolf")  # guild earns the tabard
	assert_true(
		"guild_tabard_vanguard" in GuildAchievementStore.guild_cosmetic_unlocks(gid),
		"the guild's earned set yields the tabard",
	)
	var in_guild := WardrobeOps.unlocks_for(bcid)
	assert_true(
		"guild_tabard_vanguard" in in_guild, "member may wear the guild tabard while in guild"
	)
	assert_true("cos_gilded_blade" in in_guild, "own purchase is also wearable")
	# bob leaves — the guild identity is no longer his, but his own item survives untouched.
	GuildStore.op({"username": "bob", "action": "leave"})
	var after_leave := WardrobeOps.unlocks_for(bcid)
	assert_false(
		"guild_tabard_vanguard" in after_leave, "leaving drops the guild-earned tabard eligibility"
	)
	assert_true("cos_gilded_blade" in after_leave, "individually-owned unlock is never destroyed")


func test_kick_also_drops_guild_cosmetic_eligibility() -> void:
	var g := _guild_of_two()
	var gid: int = g[0]
	var bcid: int = g[2]
	GuildAchievementStore.observe(gid, "guild_kill", "wolf")
	assert_true("guild_tabard_vanguard" in WardrobeOps.unlocks_for(bcid), "eligible while a member")
	GuildStore.op({"username": "alice", "action": "kick", "target_name": "bob"})
	assert_false(
		"guild_tabard_vanguard" in WardrobeOps.unlocks_for(bcid),
		"a kicked member loses guild-earned eligibility",
	)


# ---- presence milestone (server-fed online count) -------------------------------


func test_online_presence_is_a_max_highwater_and_server_fed() -> void:
	GuildAchievementRegistry._override_for_test(
		[
			{
				"id": "g_fellowship",
				"criteria": {"event": "guild_online", "key": "*", "count": 3},
				"reward": {}
			}
		]
	)
	var g := _guild_of_two()
	var gid: int = g[0]
	# The world feeds the authoritative online count through the actor-less note_presence path.
	GuildStore.op({"action": "note_presence", "guild_id": gid, "online_count": 2})
	assert_false(_earned(gid, "g_fellowship"), "2 online is short of the milestone")
	var hit := GuildStore.op({"action": "note_presence", "guild_id": gid, "online_count": 3})
	assert_true("g_fellowship" in _ids(hit.get("guild_achievements", [])), "3 online resolves it")
	# A later lower count never lowers the peak / re-fires.
	GuildStore.op({"action": "note_presence", "guild_id": gid, "online_count": 1})
	assert_true(_earned(gid, "g_fellowship"), "peak milestone stays earned when the count drops")


# ---- T-700 Stage 1: batched-delta counter write --------------------------------


# One guild observe = ONE batched counter-write invocation (was: one psql subprocess per counter
# key); the delta persists only the changed keys, not the whole owned set; a no-op writes nothing.
func test_observe_batches_writes_to_one_invocation_of_changed_keys() -> void:
	var g := _guild_of_two()
	var gid: int = g[0]
	for m in ["a", "b", "c", "d", "e"]:  # build up guild_kill:* + per-mob keys (+ earn-derived metas)
		GuildAchievementStore.observe(gid, "guild_kill", m)
	GuildAchievementStore._persist_invocations = 0
	GuildAchievementStore.observe(gid, "guild_kill", "f")  # new mob, nothing new earns here
	assert_eq(GuildAchievementStore._persist_invocations, 1, "a single batched write, not per key")
	var keys: Array = GuildAchievementStore._last_persisted_keys
	assert_eq(keys.size(), 2, "only the running total + the new per-mob tally, not every owned key")
	assert_true("guild_kill:*" in keys and "guild_kill:f" in keys)
	# guild_online at the same peak is a no-op -> no write.
	GuildAchievementStore.observe(gid, "guild_online", "*", 4)
	GuildAchievementStore._persist_invocations = 0
	GuildAchievementStore.observe(gid, "guild_online", "*", 4)
	assert_eq(GuildAchievementStore._persist_invocations, 0, "unchanged high-water writes nothing")


# ---- helpers --------------------------------------------------------------------


func _ids(defs: Array) -> Array:
	var out: Array = []
	for d: Dictionary in defs:
		out.append(str(d.get("id", "")))
	return out


func _earned(gid: int, aid: String) -> bool:
	for row: Dictionary in GuildAchievementStore.list(gid)["achievements"]:
		if str(row["id"]) == aid:
			return bool(row["earned"])
	return false


func _fraction(listed: Dictionary, aid: String) -> float:
	for row: Dictionary in listed["achievements"]:
		if str(row["id"]) == aid:
			return float(row["fraction"])
	return -1.0
