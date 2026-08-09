class_name TravelOps
extends RefCounted

# T-431: persistent travel authority. The world owns route topology, NPC proximity, destinations,
# and prices; master owns per-character discovery and coins. A hop commits only when source+dest are
# both learned and the authoritative purse can cover the world-authored cost. Successful debits ride
# ServicesStore.adjust_coins(reason="flight"), so econ.coin_ledger remains the one accounting path.

const _CM := preload("res://scripts/character_manager.gd")
const _SS := preload("res://scripts/services_store.gd")
const _PH := preload("res://scripts/pvp_honor.gd")  # T-375 cosmetic unlock read seam
const _CL := preload("res://scripts/coin_ledger.gd")  # T-658: REASON_MOUNT_TRAINING

const BASELINE_MOUNT := "mount_common_gryphon"

# T-658: one-time learn-to-ride coin sink. Level lands on the Era-1 cap (leveling.gd
# ERA_LEVEL_CAPS[1] = 20) — the natural "you've outgrown the starting zone" milestone — and the
# price sits between a talent reroll and a vault-tier-1 upgrade (150 / 750 / 1500): a real
# save-toward goal at that level, not an impulse buy. Both consts are the single tuning knob.
const MOUNT_TRAIN_LEVEL := 20
const MOUNT_TRAIN_COST := 750

static var _test_known: Dictionary = {}  # cid -> Array[String]
static var _test_profiles: Dictionary = {}  # cid -> {learned,mount_id,skin}


static func reset_for_test() -> void:
	_test_known.clear()
	_test_profiles.clear()


static func op(params: Dictionary) -> Dictionary:
	var character: Dictionary = _CM.get_character(str(params.get("username", "")))
	if character.is_empty():
		return {"error": "unknown_character"}
	var cid := int(character.get("id", -1))
	match str(params.get("action", "")):
		"discover":
			var node := str(params.get("node", ""))
			if node == "":
				return {"error": "unknown_roost"}
			_grant_node(cid, node)
			return {"ok": true, "known_nodes": known_nodes(cid), "coins": _SS.get_coins(cid)}
		"list":
			return {"ok": true, "known_nodes": known_nodes(cid), "coins": _SS.get_coins(cid)}
		"fly":
			return _fly(cid, params)
		"learn_mount":
			return _learn_mount(cid, character)
	return {"error": "bad_action"}


static func known_nodes(cid: int) -> Array:
	if _CM._test_skip_db:
		return (_test_known.get(cid, []) as Array).duplicate()
	var out: Array = []
	for row: Dictionary in _CM.db_query(
		"SELECT node_id FROM chars.character_flight_nodes WHERE character_id=$1 ORDER BY node_id",
		[cid]
	):
		out.append(str(row.get("node_id", "")))
	return out


static func mount_profile(cid: int) -> Dictionary:
	if _CM._test_skip_db:
		# T-658: a character with no profile set is a FRESH one — matches migration 048's new
		# DEFAULT false. Existing-character-keeps-free-mount is a migration-time backfill (real
		# DB rows only); the test double has no "existing before the migration" concept, so tests
		# that need a pre-learned character call test_set_mount_profile explicitly.
		var profile: Dictionary = (
			_test_profiles
			. get(cid, {"learned": false, "mount_id": BASELINE_MOUNT, "skin": ""})
			. duplicate()
		)
		return _validated_profile(cid, profile)
	var rows := _CM.db_query(
		"SELECT learned_mount, active_mount, mount_skin FROM chars.characters WHERE id=$1", [cid]
	)
	if rows.is_empty():
		return {"learned": false, "mount_id": "", "skin": ""}
	var row: Dictionary = rows[0]
	return _validated_profile(
		cid,
		{
			"learned": _is_db_true(row.get("learned_mount", false)),
			"mount_id": str(row.get("active_mount", BASELINE_MOUNT)),
			"skin": str(row.get("mount_skin", "")),
		}
	)


static func test_set_mount_profile(cid: int, profile: Dictionary) -> void:
	_test_profiles[cid] = profile.duplicate()


# T-563: a hydrated DB row carries boolean columns as "t"/"f" STRINGS. bool(<String>) is an
# "Invalid call. Nonexistent 'bool' constructor" crash — live-only, because the _test_skip_db
# mock path supplies real bools (which is why a green suite never saw it). Convert through this
# codebase-standard truthy reader (mirrors ops_store._db_bool / inventory_persist._is_db_true).
static func _is_db_true(v: Variant) -> bool:
	return v if v is bool else str(v).to_lower() in ["t", "true", "1"]


static func _validated_profile(cid: int, profile: Dictionary) -> Dictionary:
	# The visual rides T-375's unlock inventory. A stale/forged selection fails closed to baseline.
	var skin := str(profile.get("skin", ""))
	if skin != "" and not skin in _PH.unlocks_for(cid):
		skin = ""
	return {
		"learned": bool(profile.get("learned", false)),
		"mount_id": str(profile.get("mount_id", BASELINE_MOUNT)),
		"skin": skin,
	}


static func _fly(cid: int, params: Dictionary) -> Dictionary:
	var source := str(params.get("source", ""))
	var dest := str(params.get("dest", ""))
	var cost := int(params.get("cost", -1))
	var known := known_nodes(cid)
	if source == "" or dest == "" or source == dest or not source in known or not dest in known:
		return {"error": "unknown_roost"}
	if cost <= 0:
		return {"error": "bad_cost"}
	if not _SS.adjust_coins(cid, -cost, "flight"):
		return {"error": "insufficient_coins", "coins": _SS.get_coins(cid)}
	return {"ok": true, "coins": _SS.get_coins(cid), "dest": dest}


# T-658: the one-time riding-trainer purchase. Mirrors _fly's shape (pre-validate every reason a
# purchase can fail, THEN a single ServicesStore.adjust_coins debit) but the "destination" here is
# a permanent learned_mount flag, not a position. Fail-closed order matters: already-learned first
# (a second attempt is a no-op, never a second charge), then the level gate, then the purse — so a
# rejected purchase for ANY reason never touches coins or the ledger.
static func _learn_mount(cid: int, character: Dictionary) -> Dictionary:
	if bool(mount_profile(cid).get("learned", false)):
		return {"error": "already_learned"}
	if int(character.get("level", 1)) < MOUNT_TRAIN_LEVEL:
		return {"error": "level_too_low"}
	if not _SS.adjust_coins(cid, -MOUNT_TRAIN_COST, _CL.REASON_MOUNT_TRAINING):
		return {"error": "insufficient_coins", "coins": _SS.get_coins(cid)}
	_set_learned_mount(cid)
	return {"ok": true, "learned": true, "coins": _SS.get_coins(cid)}


static func _set_learned_mount(cid: int) -> void:
	if _CM._test_skip_db:
		var profile: Dictionary = mount_profile(cid)
		profile["learned"] = true
		_test_profiles[cid] = profile
		return
	_CM.db_execute("UPDATE chars.characters SET learned_mount = TRUE WHERE id = $1", [cid])


static func _grant_node(cid: int, node: String) -> void:
	if _CM._test_skip_db:
		var known: Array = _test_known.get(cid, [])
		if not node in known:
			known.append(node)
			known.sort()
		_test_known[cid] = known
		return
	_CM.db_execute(
		(
			"INSERT INTO chars.character_flight_nodes(character_id,node_id) VALUES($1,$2) "
			+ "ON CONFLICT DO NOTHING"
		),
		[cid, node]
	)
