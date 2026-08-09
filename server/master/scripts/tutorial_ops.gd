# T-426: master-side tutorial credit + skill-acquisition telemetry, carved out of main.gd (at the
# 1000-line cap). Two verb-credit forwarders (use_ability, interrupt) plus the server-observed
# skill-acquisition signals the fun-audit funnel measures. Everything here is server-authoritative:
# the world only ever forwards an event the SERVER validated (an accepted ability, a detected
# telegraph break, an atomic turn-in) — no client asserts skill acquisition, and this only ever
# credits an already-active objective or appends a read-only telemetry row.
extends RefCounted

const CharacterManager = preload("res://scripts/character_manager.gd")
const TelemetryStore = preload("res://scripts/telemetry_store.gd")
const OnboardingStore = preload("res://scripts/onboarding_store.gd")  # T-550 account graduation

# T-426: tutorial quest id -> the skill-acquisition funnel event emitted when it is turned in.
# q_tut_03 is intentionally absent: its tactical skill is measured at the interrupt-credit moment
# (credit_interrupt below) — when the skill is actually performed, not when the quest is handed in.
const _QUEST_ACQUIRE_EVENT := {
	"q_tut_01": "tutorial_basics",  # move + attack + loot performed
	"q_tut_02": "tutorial_kit",  # equip + use-ability performed
}


# T-426: world-observed use_ability credit (tutorial verb). Moved verbatim from main._credit_ability
# to bank room under the master main.gd line cap.
static func credit_ability(
	username: String, ability_slug: String, quest_defs: Dictionary
) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"credited": []}
	var cid := int(character.get("id", -1))
	return CharacterManager.credit_event(cid, "use_ability", ability_slug, quest_defs)


# T-426 slice 4: world-observed interrupt credit (the tactical verb — a broken effigy telegraph).
# On a real credit, emit the tutorial_tactics acquisition signal: the encounter is CLEARED the
# instant the interrupt lands, independent of turning the quest in.
static func credit_interrupt(
	username: String, mob_alias: String, quest_defs: Dictionary
) -> Dictionary:
	var character: Dictionary = CharacterManager.get_character(username)
	if character.is_empty():
		return {"credited": []}
	var cid := int(character.get("id", -1))
	var result: Dictionary = CharacterManager.credit_event(cid, "interrupt", mob_alias, quest_defs)
	if not (result.get("credited", []) as Array).is_empty():
		TelemetryStore.record_tutorial_step(username, "tutorial_tactics")
	return result


# T-426: a successfully turned-in tutorial quest is the server-observed proof its verbs were
# performed. Fire-and-forget the matching skill-acquisition signal (no-op for a non-tutorial quest).
static func note_quest_completion(username: String, quest_id: String) -> void:
	var event := str(_QUEST_ACQUIRE_EVENT.get(quest_id, ""))
	if event != "":
		TelemetryStore.record_tutorial_step(username, event)
	# T-550: turning in the graduation quest marks the ACCOUNT tutorial-done, so alts aren't
	# force-fed the chain. Resolved from the character server-side; inert for any other quest.
	note_graduation(str(CharacterManager.get_character(username).get("username", "")), quest_id)


# T-550: graduate the account when q_tut_03 is turned in. `account` is the login account
# (chars.characters.username), resolved server-side — never client-supplied. Inert otherwise.
static func note_graduation(account: String, quest_id: String) -> void:
	if quest_id == OnboardingStore.GRADUATION_QUEST:
		OnboardingStore.mark_tutorial_done(account)


# T-550: master-op passthrough for the onboarding_hint_seen intent — keeps the dispatcher (at its
# 1000-line cap) from a second onboarding preload. The store resolves the account server-side.
# T-711: each accepted sighting is also a hint-impression telemetry row (pairs with the T-705
# funnel). The client only reports a hint the moment it actually showed, and the store's fire-once
# row means this fires at most once per (account, hint) — first impressions, exactly what the
# stall-detector acceptance measures.
static func record_hint_seen(params: Dictionary) -> Dictionary:
	var result := OnboardingStore.record_hint_seen(params)
	if bool(result.get("ok", false)):
		var who := str(params.get("username", ""))
		(
			TelemetryStore
			. record_events(
				[
					{
						"event_type": "hint_impression",
						"account": who,
						"character": who,
						"payload": {"hint_id": str(result.get("hint_id", ""))},
					}
				]
			)
		)
	return result
