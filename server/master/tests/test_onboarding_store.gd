extends GutTest
# T-550: ACCOUNT-level onboarding state — the seam that makes tutorial-skip + control hints agree
# across the multi-character era (T-507). Proves the store is account-keyed + server-authoritative:
#   * a fresh account is FORCED (guided) through the tutorial; once graduated it is only OFFERED.
#   * graduation is set only by the server-observed q_tut_03 turn-in — no client verb forges it.
#   * control-hint fire-once memory is keyed per (account, hint_id): the account's first character
#     sees every hint; an alt (any device) never re-nags one the account already saw.

const OnboardingStore = preload("res://scripts/onboarding_store.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()  # also flips _test_skip_db on -> in-memory store
	OnboardingStore.reset_for_test()


# ---- tutorial graduation (auto-skip for alts) ---------------------------------


func test_fresh_account_is_forced_then_graduated_is_only_offered() -> void:
	# First-ever character on an account: not graduated -> the guided chain is FORCED.
	assert_false(OnboardingStore.is_tutorial_done("acct_main"), "a fresh account has not graduated")
	assert_true(
		OnboardingStore.should_force_tutorial(OnboardingStore.is_tutorial_done("acct_main")),
		"the account's first character is force-fed the guided onboarding"
	)
	# The account graduates (any character turns in q_tut_03).
	OnboardingStore.mark_tutorial_done("acct_main")
	assert_true(
		OnboardingStore.is_tutorial_done("acct_main"), "graduation persists at account scope"
	)
	assert_false(
		OnboardingStore.should_force_tutorial(OnboardingStore.is_tutorial_done("acct_main")),
		"an alt on a graduated account is NOT forced (only offered)"
	)


func test_graduation_is_per_account_not_global() -> void:
	OnboardingStore.mark_tutorial_done("acct_main")
	# A brand-new player on a DIFFERENT account still gets the full guided onboarding.
	assert_false(
		OnboardingStore.is_tutorial_done("acct_other"), "graduation never leaks across accounts"
	)
	assert_true(
		OnboardingStore.should_force_tutorial(OnboardingStore.is_tutorial_done("acct_other")),
		"a different account's first character is still forced"
	)


func test_mark_tutorial_done_is_idempotent() -> void:
	OnboardingStore.mark_tutorial_done("acct_main")
	OnboardingStore.mark_tutorial_done("acct_main")  # re-graduating is harmless
	assert_true(OnboardingStore.is_tutorial_done("acct_main"))


func test_empty_account_never_graduates() -> void:
	OnboardingStore.mark_tutorial_done("")  # no-op guard
	assert_false(
		OnboardingStore.is_tutorial_done(""), "an empty account is never treated as graduated"
	)


# ---- control-hint fire-once memory (account-scoped) ---------------------------


func test_hint_memory_is_account_and_id_scoped() -> void:
	assert_false(
		OnboardingStore.has_seen_hint("acct_main", "move"), "the account has seen no hints yet"
	)
	OnboardingStore.mark_hint_seen("acct_main", "move")
	assert_true(OnboardingStore.has_seen_hint("acct_main", "move"), "the sighting persists")
	assert_false(OnboardingStore.has_seen_hint("acct_main", "target"), "memory is per hint id")
	assert_false(OnboardingStore.has_seen_hint("acct_other", "move"), "and per account")


func test_mark_hint_seen_is_idempotent() -> void:
	OnboardingStore.mark_hint_seen("acct_main", "move")
	OnboardingStore.mark_hint_seen("acct_main", "move")
	assert_eq(OnboardingStore.seen_hints("acct_main"), ["move"], "a re-report adds no duplicate")


func test_seen_hints_bundles_the_account_state_for_the_handshake() -> void:
	OnboardingStore.mark_hint_seen("acct_main", "move")
	OnboardingStore.mark_hint_seen("acct_main", "target")
	OnboardingStore.mark_tutorial_done("acct_main")
	var state := OnboardingStore.account_state("acct_main")
	assert_true(bool(state["tutorial_done"]), "the bundle carries graduation")
	assert_true((state["hints_seen"] as Array).has("move"), "and every seen hint")
	assert_true((state["hints_seen"] as Array).has("target"))
	# A fresh account's bundle is empty -> its first character gets everything.
	var fresh := OnboardingStore.account_state("acct_other")
	assert_false(bool(fresh["tutorial_done"]), "a fresh account has not graduated")
	assert_eq(fresh["hints_seen"], [], "and has seen no hints")


# T-710: should_force_tutorial is WIRED into the handshake bundle — the world reads force_tutorial
# to decide the first-entry offer push, so the gate is live code, not a test-only helper.
func test_account_state_wires_force_tutorial() -> void:
	var fresh := OnboardingStore.account_state("acct_new")
	assert_true(bool(fresh["force_tutorial"]), "a fresh account's bundle says FORCE the tutorial")
	OnboardingStore.mark_tutorial_done("acct_new")
	var grad := OnboardingStore.account_state("acct_new")
	assert_false(
		bool(grad["force_tutorial"]), "a graduated account's alts are only offered, never forced"
	)
	assert_true(bool(grad["tutorial_done"]), "and the graduation flag agrees")


func test_empty_account_hint_calls_are_safe() -> void:
	OnboardingStore.mark_hint_seen("", "move")
	OnboardingStore.mark_hint_seen("acct_main", "")
	assert_false(OnboardingStore.has_seen_hint("", "move"))
	assert_false(OnboardingStore.has_seen_hint("acct_main", ""))


# T-563 regression: is_tutorial_done's DB path hydrates tutorial_done as a Postgres "t"/"f" STRING
# and fed it to bool(<String>) -> the live "Nonexistent 'bool' constructor" crash (portal report
# #17). The _test_skip_db mock stores native bools, so the suite passed while the real spawn-payload
# read crashed. Unit-test the truthy reader against the "t"/"f" string path the mock skipped.
func test_is_db_true_reads_postgres_tf_strings_without_crashing() -> void:
	assert_true(OnboardingStore._is_db_true("t"), '"t" (a graduated account) reads true')
	assert_false(OnboardingStore._is_db_true("f"), '"f" reads false -- and does NOT crash')
	assert_true(OnboardingStore._is_db_true("true"))
	assert_false(OnboardingStore._is_db_true("false"))
	assert_true(OnboardingStore._is_db_true("1"))
	assert_false(OnboardingStore._is_db_true("0"))
	# Native bools (the mock path + already-parsed JSON) still pass straight through.
	assert_true(OnboardingStore._is_db_true(true))
	assert_false(OnboardingStore._is_db_true(false))
	assert_false(OnboardingStore._is_db_true(""), "a stale/empty string fails closed, not truthy")
