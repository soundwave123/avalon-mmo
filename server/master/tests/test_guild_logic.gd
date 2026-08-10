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


# ---- T-755: the master must not STORE a bbcode payload ------------------------
#
# The client escape is the real fix (a server cannot know what every client will do with a
# string). These pin the defence-in-depth half: the blurb was the one free-text field with no
# charset rule at all, which is what made the guild-panel injection live rather than theoretical.
func test_recruitment_blurb_rejects_bbcode_payloads() -> void:
	assert_false(
		GuildLogic.valid_recruitment_blurb("[url=kick|victim]\\[x\\][/url]"),
		"the forged-management-link payload never reaches the database"
	)
	assert_false(GuildLogic.valid_recruitment_blurb("[color=red]look at me"), "no opening tag")
	assert_false(
		GuildLogic.valid_recruitment_blurb("no opener but a closer]"),
		"a lone ']' can still close a tag opened by an adjacent field"
	)
	# The rule must not tax honest recruiters: ordinary punctuation still publishes.
	assert_true(
		GuildLogic.valid_recruitment_blurb("Raids Tue/Thu 8pm — friendly, 18+, no drama!"),
		"a normal blurb is unaffected"
	)


func test_has_markup_needs_no_list_of_tag_names() -> void:
	# Brackets are the entire vocabulary of a BBCode tag, so this predicate stays correct without
	# tracking whatever tags Godot's parser gains next.
	assert_true(GuildLogic.has_markup("[b]"))
	assert_true(GuildLogic.has_markup("a]b"))
	assert_true(GuildLogic.has_markup("[some_tag_godot_does_not_have_yet]"))
	assert_false(GuildLogic.has_markup("Knights of Valor"))
	assert_false(GuildLogic.has_markup(""))


func test_guild_names_were_already_closed_to_markup() -> void:
	# valid_name is an alphanumeric ALLOWLIST, so it always refused brackets — this is the
	# regression pin that says so out loud, since the guild NAME is rendered by the same panel and
	# a future loosening of this rule would silently re-open the hole.
	assert_false(GuildLogic.valid_name("[b]Knights"), "a guild name cannot carry markup")
	assert_false(GuildLogic.valid_name("Knights]"), "...in either direction")


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
