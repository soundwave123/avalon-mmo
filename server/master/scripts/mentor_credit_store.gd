class_name MentorCreditStore
extends RefCounted

# T-481 master authority for persistent mentor recognition. The only caller is the existing
# server-observed kill-credit path; persisted level replaces any producer claim before pure accrual.

const _MC := preload("res://scripts/mentor_credit.gd")
const _CM := preload("res://scripts/character_manager.gd")
const _LV := preload("res://scripts/leveling.gd")
const _ACH := preload("res://scripts/achievement_store.gd")
const _PVP := preload("res://scripts/pvp_honor.gd")
const _WARDROBE := preload("res://scripts/wardrobe_ops.gd")
const _TEL := preload("res://scripts/telemetry_store.gd")

static var _test_credit: Dictionary = {}  # cid -> int
static var _test_grants: Dictionary = {}  # cid -> {grant_key: true}


static func reset_for_test() -> void:
	_test_credit.clear()
	_test_grants.clear()


# mentor_context is world-held opt-in/effective-level truth. content_id comes from the mob that the
# world just adjudicated dead; an empty id cannot become a completion.
static func observe_completion(
	username: String, mentor_context: Dictionary, content_id: String
) -> Dictionary:
	var character := _CM.get_character(username)
	if character.is_empty():
		return {"ok": false, "credit": 0, "credit_delta": 0, "unlocks": [], "achievements": []}
	var cid := int(character.get("id", -1))
	var observation := {
		"opted_in": bool(mentor_context.get("opted_in", false)),
		"effective_level": int(mentor_context.get("effective_level", -1)),
		"true_level": int(character.get("level", 1)),
		"max_level": _LV.MAX_LEVEL,
		"content_completed": content_id != "",
		"active_participation": bool(mentor_context.get("active_participation", false)),
	}
	if not _MC.eligible(observation):
		return {"ok": true, "credit": 0, "credit_delta": 0, "unlocks": [], "achievements": []}
	var decision := _MC.accrue(state_for(cid), observation)
	if int(decision["credit_delta"]) == 0:
		return {
			"ok": true,
			"credit": int(decision["state"]["credit"]),
			"credit_delta": 0,
			"unlocks": [],
			"achievements": [],
		}
	_persist_credit(cid, int(decision["state"]["credit"]))
	var unlocked: Array = []
	for grant: Dictionary in decision["grants"]:
		if not _claim_grant(cid, str(grant["key"])):
			continue
		_land_grant(cid, grant)
		unlocked.append(grant.duplicate(true))
	var observed := _ACH.observe(cid, "mentor_credit", "*", int(decision["state"]["credit"]))
	_emit(username, content_id, int(decision["state"]["credit"]), unlocked)
	return {
		"ok": true,
		"credit": int(decision["state"]["credit"]),
		"credit_delta": int(decision["credit_delta"]),
		"unlocks": unlocked,
		"achievements": observed.get("newly_earned", []),
	}


static func state_for(cid: int) -> Dictionary:
	if _CM._test_skip_db:
		return {
			"credit": int(_test_credit.get(cid, 0)),
			"granted": (_test_grants.get(cid, {}) as Dictionary).keys(),
		}
	var credit_rows := _CM.db_query(
		"SELECT credit FROM chars.character_mentor_credit WHERE character_id=$1", [cid]
	)
	var grants: Array = []
	for row: Dictionary in _CM.db_query(
		"SELECT grant_key FROM chars.character_mentor_grant WHERE character_id=$1", [cid]
	):
		grants.append(str(row.get("grant_key", "")))
	return {
		"credit": int(credit_rows[0].get("credit", 0)) if not credit_rows.is_empty() else 0,
		"granted": grants,
	}


static func _persist_credit(cid: int, credit: int) -> void:
	if _CM._test_skip_db:
		_test_credit[cid] = credit
		return
	_CM.db_execute(
		(
			"INSERT INTO chars.character_mentor_credit(character_id,credit) VALUES($1,$2) "
			+ "ON CONFLICT(character_id) DO UPDATE SET credit=GREATEST("
			+ "chars.character_mentor_credit.credit,EXCLUDED.credit),updated_at=now()"
		),
		[cid, credit]
	)


static func _claim_grant(cid: int, grant_key: String) -> bool:
	if _CM._test_skip_db:
		var mine: Dictionary = _test_grants.get(cid, {})
		if mine.has(grant_key):
			return false
		mine[grant_key] = true
		_test_grants[cid] = mine
		return true
	var rows := _CM.db_query(
		(
			"INSERT INTO chars.character_mentor_grant(character_id,grant_key) VALUES($1,$2) "
			+ "ON CONFLICT DO NOTHING RETURNING grant_key"
		),
		[cid, grant_key]
	)
	return not rows.is_empty()


static func _land_grant(cid: int, grant: Dictionary) -> void:
	match str(grant.get("kind", "")):
		"title":
			_PVP.grant_unlock(cid, str(grant.get("id", "")))
		"cosmetic":
			_WARDROBE.grant_unlock(cid, str(grant.get("id", "")))


static func _emit(username: String, content_id: String, credit: int, grants: Array) -> void:
	var events: Array = [
		{
			"event_type": "mentor_credit",
			"account": username,
			"character": username,
			"payload": {"content_id": content_id, "credit": credit, "delta": 1},
		}
	]
	for grant: Dictionary in grants:
		(
			events
			. append(
				{
					"event_type": "mentor_unlock",
					"account": username,
					"character": username,
					"payload":
					{
						"credit": credit,
						"kind": str(grant.get("kind", "")),
						"unlock_id": str(grant.get("id", "")),
					},
				}
			)
		)
	_TEL.record_events(events)
