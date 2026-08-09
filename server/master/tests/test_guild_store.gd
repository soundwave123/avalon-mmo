extends GutTest

# T-362: guild persistence + the full authority surface. Runs against the test-mode fakes (the suite
# pattern) so it needs no live Postgres. Every ticket assertion is covered:
#   - only invite-ranked can invite; only leader disbands; kick/promote respect ranks
#   - membership + ranks survive a "relog" (re-read); a disbanded guild frees its name
#   - creation debits the coin cost and fails cleanly when the founder can't afford it

const CharacterManager = preload("res://scripts/character_manager.gd")
const ServicesStore = preload("res://scripts/services_store.gd")
const _GS = preload("res://scripts/guild_store.gd")
const GuildLogic = preload("res://scripts/guild_logic.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()


func _mk(username: String, coins: int = 5000) -> int:
	CharacterManager.ensure_character(username)
	var cid := int(CharacterManager.get_character(username)["id"])
	# get_coins defaults to 100 in test mode; set an explicit balance for cost assertions.
	ServicesStore.adjust_coins(cid, coins - ServicesStore.get_coins(cid))
	return cid


func _found(leader: String, name: String = "Knights") -> Dictionary:
	return _GS.op({"username": leader, "action": "create", "name": name})


# error-string shorthand for the many single-line rejection assertions
func _err(user: String, action: String, target: String = "") -> String:
	return str(_GS.op({"username": user, "action": action, "target_name": target}).get("error", ""))


func test_create_debits_cost_and_seats_leader() -> void:
	var lid := _mk("alice", 5000)
	var r := _found("alice", "Knights of Valor")
	assert_true(bool(r.get("created", false)))
	assert_eq(int(r["cost"]), _GS.CREATE_COST)
	assert_eq(ServicesStore.get_coins(lid), 5000 - _GS.CREATE_COST, "founder debited")
	assert_eq(_GS.guild_id_for(lid), int(r["guild_id"]))
	assert_eq(int(r["members"][0]["rank"]), GuildLogic.RANK_LEADER)


func test_create_fails_clean_when_broke() -> void:
	var lid := _mk("poor", _GS.CREATE_COST - 1)
	var r := _found("poor")
	assert_eq(str(r.get("error", "")), "insufficient_coins")
	assert_eq(ServicesStore.get_coins(lid), _GS.CREATE_COST - 1, "no coin moved on a failed create")
	assert_eq(_GS.guild_id_for(lid), 0, "no guild born")


func test_create_rejects_bad_and_taken_names_and_double_guild() -> void:
	_mk("alice")
	_mk("bob")
	assert_eq(str(_found("alice", "no").get("error")), "bad_name")
	_found("alice", "Knights")
	# case-insensitive uniqueness
	assert_eq(str(_found("bob", "KNIGHTS").get("error")), "name_taken")
	# alice already leads a guild
	assert_eq(str(_found("alice", "Second").get("error")), "already_in_guild")


func test_invite_accept_flow_and_permission_gate() -> void:
	_mk("alice")
	_mk("bob")
	_mk("carol")
	var g := _found("alice")
	var gid := int(g["guild_id"])
	# A member cannot invite: add bob first (as member), then bob tries to invite carol.
	_GS.op({"username": "alice", "action": "invite", "target_name": "bob"})
	var acc := _GS.op({"username": "bob", "action": "accept"})
	assert_true(bool(acc.get("joined", false)))
	assert_eq(_GS.guild_id_for(int(CharacterManager.get_character("bob")["id"])), gid)
	var denied := _GS.op({"username": "bob", "action": "invite", "target_name": "carol"})
	assert_eq(str(denied.get("error", "")), "no_permission", "a member has no invite power")
	# Accept with no pending invite is rejected.
	assert_eq(str(_GS.op({"username": "carol", "action": "accept"}).get("error")), "no_invite")


func test_invite_rejects_already_guilded_target() -> void:
	_mk("alice")
	_mk("bob")
	_found("alice", "One")
	_found("bob", "Two")
	var r := _GS.op({"username": "alice", "action": "invite", "target_name": "bob"})
	assert_eq(str(r.get("error", "")), "target_in_guild")


func test_kick_and_promote_respect_ranks() -> void:
	_mk("alice")  # leader
	_mk("bob")  # will be officer
	_mk("carol")  # member
	_found("alice")
	for who in ["bob", "carol"]:
		_GS.op({"username": "alice", "action": "invite", "target_name": who})
		_GS.op({"username": who, "action": "accept"})
	# Promote bob to officer (leader-only).
	assert_eq(_err("carol", "promote", "bob"), "no_permission")
	_GS.op({"username": "alice", "action": "promote", "target_name": "bob"})
	var bid := int(CharacterManager.get_character("bob")["id"])
	var roster := _GS.op({"username": "alice", "action": "roster"})
	assert_eq(int(roster["members"][1]["rank"]), GuildLogic.RANK_OFFICER)
	# Officer bob can kick member carol but NOT the leader.
	assert_eq(_err("bob", "kick", "alice"), "no_permission")
	var kick := _GS.op({"username": "bob", "action": "kick", "target_name": "carol"})
	assert_eq(str(kick.get("kicked", "")), "carol")
	assert_eq(
		_GS.guild_id_for(int(CharacterManager.get_character("carol")["id"])), 0, "carol removed"
	)
	assert_true(bid > 0)


func test_leader_cannot_leave_must_disband_which_frees_name() -> void:
	_mk("alice")
	_mk("bob")
	var g := _found("alice", "Knights")
	_GS.op({"username": "alice", "action": "invite", "target_name": "bob"})
	_GS.op({"username": "bob", "action": "accept"})
	assert_eq(_err("alice", "leave"), "leader_must_disband")
	# A member CAN leave.
	assert_true(bool(_GS.op({"username": "bob", "action": "leave"}).get("left", false)))
	# Disband frees the name + removes all members.
	var d := _GS.op({"username": "alice", "action": "disband"})
	assert_true(bool(d.get("disbanded", false)))
	assert_eq(_GS.guild_id_for(int(CharacterManager.get_character("alice")["id"])), 0)
	var reuse := _found("bob", "Knights")
	assert_true(bool(reuse.get("created", false)), "disbanded guild's name is reusable")
	assert_true(int(g["guild_id"]) > 0)


func test_accept_after_disband_is_rejected() -> void:
	_mk("alice")
	_mk("bob")
	_found("alice")
	_GS.op({"username": "alice", "action": "invite", "target_name": "bob"})
	_GS.op({"username": "alice", "action": "disband"})
	# The pending invite was cleared when the guild died.
	assert_eq(str(_GS.op({"username": "bob", "action": "accept"}).get("error")), "no_invite")


func test_membership_persists_across_reread() -> void:
	# "Relog" = a fresh read of the same store — no in-memory session cache is consulted.
	_mk("alice")
	_mk("bob")
	var g := _found("alice")
	_GS.op({"username": "alice", "action": "invite", "target_name": "bob"})
	_GS.op({"username": "bob", "action": "accept"})
	var roster := _GS.op({"username": "bob", "action": "roster"})
	assert_eq(int(roster["guild_id"]), int(g["guild_id"]))
	assert_eq(roster["members"].size(), 2)


# T-451: a guildless player can discover an open guild without a prior invite. Recruitment edits
# use the existing can_invite rank gate; browsing is a public read and closed guilds stay private.
func test_public_recruitment_browse_and_authority() -> void:
	_mk("alice")
	_mk("bob")
	_mk("carol")
	_found("alice", "Knights")
	_GS.op({"username": "alice", "action": "invite", "target_name": "bob"})
	_GS.op({"username": "bob", "action": "accept"})
	var denied := (
		_GS
		. op(
			{
				"username": "bob",
				"action": "set_recruitment",
				"open": true,
				"blurb": "I am only a member",
			}
		)
	)
	assert_eq(str(denied.get("error", "")), "no_permission")
	var edited := (
		_GS
		. op(
			{
				"username": "alice",
				"action": "set_recruitment",
				"open": true,
				"blurb": "New players welcome",
			}
		)
	)
	assert_true(bool(edited.get("recruitment_open", false)))
	var browse := _GS.op({"username": "carol", "action": "browse"})
	assert_eq(browse["guilds"].size(), 1, "guildless browse needs no direct invite")
	assert_eq(str(browse["guilds"][0]["name"]), "Knights")
	assert_eq(str(browse["guilds"][0]["blurb"]), "New players welcome")
	(
		_GS
		. op(
			{
				"username": "alice",
				"action": "set_recruitment",
				"open": false,
				"blurb": "New players welcome",
			}
		)
	)
	assert_eq(_GS.op({"username": "carol", "action": "browse"})["guilds"].size(), 0)


func test_guild_profile_exposes_server_truth_for_online_discovery() -> void:
	var alice_id := _mk("alice")
	_found("alice", "Knights")
	var profile := _GS.profile_for(alice_id)
	assert_eq(str(profile["guild_name"]), "Knights")
	assert_eq(int(profile["guild_rank"]), GuildLogic.RANK_LEADER)
