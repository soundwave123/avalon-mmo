extends GutTest

# T-362: the pure rank/permission matrix — the authority decisions the store leans on. No DB.

const GuildLogic = preload("res://scripts/guild_logic.gd")


func test_rank_names_and_validity() -> void:
	assert_eq(GuildLogic.rank_name(GuildLogic.RANK_LEADER), "Leader")
	assert_eq(GuildLogic.rank_name(GuildLogic.RANK_OFFICER), "Officer")
	assert_eq(GuildLogic.rank_name(GuildLogic.RANK_MEMBER), "Member")
	assert_true(GuildLogic.is_rank(0) and GuildLogic.is_rank(2))
	assert_false(GuildLogic.is_rank(3), "no such rank")


func test_name_validation() -> void:
	assert_true(GuildLogic.valid_name("Knights of Valor"))
	assert_true(GuildLogic.valid_name("abc"))
	assert_false(GuildLogic.valid_name("ab"), "too short")
	assert_false(GuildLogic.valid_name("x".repeat(25)), "too long")
	assert_false(GuildLogic.valid_name(" Leading"), "no leading space")
	assert_false(GuildLogic.valid_name("Trailing "), "no trailing space")
	assert_false(GuildLogic.valid_name("Bad;Name"), "no punctuation")


func test_recruitment_blurb_validation() -> void:
	assert_true(GuildLogic.valid_recruitment_blurb("New players welcome. Quests on weekends."))
	assert_true(GuildLogic.valid_recruitment_blurb(""), "an open guild may use an empty blurb")
	assert_false(
		GuildLogic.valid_recruitment_blurb("x".repeat(GuildLogic.RECRUITMENT_BLURB_MAX + 1)),
		"public copy is length-bounded"
	)
	assert_false(GuildLogic.valid_recruitment_blurb("line one\nline two"), "single-line copy only")


func test_invite_permission() -> void:
	assert_true(GuildLogic.can_invite(GuildLogic.RANK_LEADER))
	assert_true(GuildLogic.can_invite(GuildLogic.RANK_OFFICER))
	assert_false(
		GuildLogic.can_invite(GuildLogic.RANK_MEMBER), "a rank-and-file member cannot invite"
	)


func test_kick_requires_strictly_outranking() -> void:
	# Leader kicks officer + member.
	assert_true(GuildLogic.can_kick(GuildLogic.RANK_LEADER, GuildLogic.RANK_OFFICER))
	assert_true(GuildLogic.can_kick(GuildLogic.RANK_LEADER, GuildLogic.RANK_MEMBER))
	# Officer kicks member only — never a peer officer or the leader.
	assert_true(GuildLogic.can_kick(GuildLogic.RANK_OFFICER, GuildLogic.RANK_MEMBER))
	assert_false(GuildLogic.can_kick(GuildLogic.RANK_OFFICER, GuildLogic.RANK_OFFICER))
	assert_false(GuildLogic.can_kick(GuildLogic.RANK_OFFICER, GuildLogic.RANK_LEADER))
	# A member kicks no one.
	assert_false(GuildLogic.can_kick(GuildLogic.RANK_MEMBER, GuildLogic.RANK_MEMBER))


func test_promote_disband_are_leader_only() -> void:
	assert_true(GuildLogic.can_promote(GuildLogic.RANK_LEADER))
	assert_false(GuildLogic.can_promote(GuildLogic.RANK_OFFICER))
	assert_true(GuildLogic.can_disband(GuildLogic.RANK_LEADER))
	assert_false(GuildLogic.can_disband(GuildLogic.RANK_OFFICER))


func test_rank_step_bounds() -> void:
	assert_eq(GuildLogic.promoted_rank(GuildLogic.RANK_MEMBER), GuildLogic.RANK_OFFICER)
	assert_eq(
		GuildLogic.promoted_rank(GuildLogic.RANK_OFFICER),
		GuildLogic.RANK_OFFICER,
		"promote never mints a second leader"
	)
	assert_eq(GuildLogic.demoted_rank(GuildLogic.RANK_OFFICER), GuildLogic.RANK_MEMBER)
	assert_eq(
		GuildLogic.demoted_rank(GuildLogic.RANK_MEMBER),
		GuildLogic.RANK_MEMBER,
		"demote floors at member"
	)
