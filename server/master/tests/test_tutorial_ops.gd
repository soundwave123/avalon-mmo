extends GutTest
# T-426: TutorialOps — the master-side tutorial credit + skill-acquisition telemetry carved out of
# main.gd. Proves credit_interrupt credits an active interrupt objective AND emits tutorial_tactics
# only on a real credit; note_quest_completion emits basics/kit for tutorial quests and is inert
# otherwise; and the moved credit_ability still credits a use_ability objective.

const TutorialOps = preload("res://scripts/tutorial_ops.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")
const OnboardingStore = preload("res://scripts/onboarding_store.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()
	TelemetryStore.reset_for_test()
	OnboardingStore.reset_for_test()


func _cid(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func _interrupt_quest() -> Dictionary:
	return {
		"id": "q_tut_03",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_drillmaster",
		"turnin_npc": "npc_drillmaster",
		"objectives": [{"type": "interrupt", "target": "mob_training_effigy", "count": 1}],
		"rewards": {"xp": 80, "coins": 40, "items": []},
	}


func _ability_quest() -> Dictionary:
	return {
		"id": "q_tut_02",
		"min_level": 1,
		"prerequisite_quest": "",
		"giver_npc": "npc_drillmaster",
		"turnin_npc": "npc_drillmaster",
		"objectives": [{"type": "use_ability", "target": "*", "count": 1}],
		"rewards": {"xp": 60, "items": []},
	}


func _event_types() -> Array:
	return TelemetryStore.test_events().map(func(e): return str(e["event_type"]))


func test_credit_interrupt_credits_and_emits_tactics() -> void:
	var cid := _cid("alice")
	CharacterManager.try_accept(cid, _interrupt_quest(), 5, true)
	var result := TutorialOps.credit_interrupt(
		"alice", "mob_training_effigy", {"q_tut_03": _interrupt_quest()}
	)
	assert_eq(result["credited"], ["q_tut_03"], "the active interrupt objective is credited")
	assert_eq(CharacterManager.get_objective_progress(cid, "q_tut_03")[0], 1, "progress persisted")
	assert_true(_event_types().has("tutorial_tactics"), "the tactical clear is measured")


func test_credit_interrupt_without_a_matching_quest_emits_nothing() -> void:
	_cid("bob")  # no interrupt quest accepted
	var result := TutorialOps.credit_interrupt("bob", "mob_training_effigy", {})
	assert_eq(result["credited"], [], "nothing credited")
	assert_false(_event_types().has("tutorial_tactics"), "no phantom acquisition signal")


func test_credit_interrupt_unknown_character_is_safe() -> void:
	var result := TutorialOps.credit_interrupt("ghost", "mob_training_effigy", {})
	assert_eq(result["credited"], [])
	assert_eq(TelemetryStore.test_events().size(), 0)


func test_note_quest_completion_emits_for_tutorial_quests() -> void:
	TutorialOps.note_quest_completion("alice", "q_tut_01")
	TutorialOps.note_quest_completion("alice", "q_tut_02")
	var types := _event_types()
	assert_true(types.has("tutorial_basics"), "q_tut_01 -> basics acquired")
	assert_true(types.has("tutorial_kit"), "q_tut_02 -> kit acquired")


func test_note_quest_completion_is_inert_for_non_tutorial_quests() -> void:
	TutorialOps.note_quest_completion("alice", "q007")
	TutorialOps.note_quest_completion("alice", "q_tut_03")  # tactics is measured at credit time
	assert_eq(TelemetryStore.test_events().size(), 0, "no skill signal for these turn-ins")


func test_note_graduation_marks_the_account_on_q_tut_03() -> void:
	# T-550: turning in the graduation quest graduates the ACCOUNT (so alts skip the forced chain).
	TutorialOps.note_graduation("acct_main", "q_tut_03")
	assert_true(
		OnboardingStore.is_tutorial_done("acct_main"), "q_tut_03 turn-in graduates the account"
	)


func test_note_graduation_is_inert_for_other_quests() -> void:
	# T-550: only the final tutorial quest graduates; any earlier/other turn-in leaves it forced.
	TutorialOps.note_graduation("acct_main", "q_tut_01")
	TutorialOps.note_graduation("acct_main", "q007")
	assert_false(
		OnboardingStore.is_tutorial_done("acct_main"),
		"non-graduation turn-ins never mark the account"
	)


# T-711: an accepted hint sighting is a hint_impression telemetry row (pairs with T-705); the
# store's fire-once row keeps it to FIRST impressions, and a bogus report emits nothing.
func test_record_hint_seen_emits_hint_impression_telemetry() -> void:
	_cid("dana")
	var result := TutorialOps.record_hint_seen({"username": "dana", "hint_id": "stall_find_hale"})
	assert_true(bool(result["ok"]), "the sighting is recorded")
	assert_true(_event_types().has("hint_impression"), "and measured as an impression")
	var event: Dictionary = TelemetryStore.test_events()[0]
	assert_eq(str(event["payload"]["hint_id"]), "stall_find_hale", "the payload names the hint")


func test_record_hint_seen_for_unknown_character_emits_nothing() -> void:
	var result := TutorialOps.record_hint_seen({"username": "ghost", "hint_id": "move"})
	assert_false(bool(result["ok"]), "no account resolves -> not ok")
	assert_eq(TelemetryStore.test_events().size(), 0, "and no phantom impression row")


func test_credit_ability_still_credits_after_the_carve() -> void:
	var cid := _cid("carol")
	CharacterManager.try_accept(cid, _ability_quest(), 5, true)
	var result := TutorialOps.credit_ability(
		"carol", "heroic_strike", {"q_tut_02": _ability_quest()}
	)
	assert_eq(result["credited"], ["q_tut_02"], "the wildcard use_ability objective still credits")
	assert_eq(CharacterManager.get_objective_progress(cid, "q_tut_02")[0], 1)
