extends RefCounted

# T-033: quest lifecycle authority (pure state machine; this module applies its decisions).
const _QSM = preload("res://scripts/quest_state_machine.gd")
# T-034: pure objective-progress logic; this module persists its output.
const _OT = preload("res://scripts/objective_tracker.gd")
# T-035: pure XP curve + class stat table; this module grants and persists XP/level.
const _LV = preload("res://scripts/leveling.gd")
# T-036: pure bag/equip/stacking model; this module persists its decisions.
const _IL = preload("res://scripts/inventory_logic.gd")
# T-064: pure talent spend validation + stat mods; this module persists the ranks.
const _TL = preload("res://scripts/talent_logic.gd")
# T-037: pure NPC indicator + talk-plan logic; this module orchestrates and persists talk credit.
const _NI = preload("res://scripts/npc_interaction.gd")
# T-319: pure class -> starting-weapon table + equipped-slot builder; this module persists it.
const _SG = preload("res://scripts/starting_gear.gd")
# T-353: pure era gear-carry re-scale (rift); this module reads inventory, runs it, persists.
const _EG = preload("res://scripts/era_gear.gd")
# T-353: inventory row <-> Postgres serialization (extracted at the file cap; owns carry columns).
const _IP = preload("res://scripts/inventory_persist.gd")
# T-360: rested-XP config + persistence (extracted at the file cap; pure math in rested_logic.gd).
const _RP = preload("res://scripts/rested_persist.gd")
# T-428: direct single-row helpers extracted before adding the wardrobe acquisition seam.
const _ID = preload("res://scripts/inventory_direct.gd")
# T-520 carve: one-shot creation choices (T-065 class + T-520 gender) — keeps this file under cap.
const _CRE = preload("res://scripts/creation_choice.gd")

const _QXP = preload("res://scripts/quest_xp.gd")  # T-621: over-level quest-XP decay
# T-701 carve: connection consts + driver plumbing live in db_bridge.gd (this file was AT the cap).
const _DB = preload("res://scripts/db_bridge.gd")

static var _test_skip_db: bool = false
static var _test_characters: Dictionary = {}
static var _test_inventory: Dictionary = {}
static var _test_quests: Dictionary = {}
static var _test_objectives: Dictionary = {}  # T-034: character_id -> { quest_id -> Array[int] }
static var _test_talents: Dictionary = {}  # T-064: character_id -> { talent_id -> ranks }
static var _test_cosmetic_unlocks: Dictionary = {}  # T-428: character_id -> Array[String]
static var _test_fail_persist: bool = false  # T-567: force a persist rollback (turn-in reject test)


static func reset_for_test() -> void:
	_test_skip_db = true
	_test_characters.clear()
	_test_inventory.clear()
	_test_quests.clear()
	_test_objectives.clear()
	_test_talents.clear()
	_test_cosmetic_unlocks.clear()
	_test_fail_persist = false  # T-567
	ServicesStore.reset_for_test()
	SocialStore.reset_for_test()  # T-361: friends/ignore lists
	GuildStore.reset_for_test()  # T-362: guilds + memberships + pending invites
	AchievementStore.reset_for_test()  # T-367: per-character achievement progress
	RenownStore.reset_for_test()  # T-678: per-character per-hub renown points
	MailStore.reset_for_test()  # T-613: mail rows + the in-memory send-rate window


static func enable_test_mode() -> void:
	reset_for_test()


# T-507: the bootstrap insert — a fresh account's FIRST character, named after the account at
# slot 0 (exactly the shape migration 044 gives every pre-existing character). No-op once the
# account owns any live character, so alt names can never spawn bogus accounts here.
static func ensure_character(username: String) -> bool:
	if _test_skip_db:
		if not _test_characters.has(username):
			var character_id := _test_characters.size() + 1
			_test_characters[username] = {
				"id": character_id,
				"username": username,
				"name": username,  # T-507: character name; == username for the bootstrap slot-0 char
				"name_chosen": false,  # T-716: the in-world name step is still owed
				"slot": 0,  # T-507
				"class": "warrior",
				"class_locked": false,  # T-065
				"gender": "",  # T-520: unchosen -> the gender panel shows before the class panel
				"xp": 0,
				"level": 1,
				"spawn_x": 5.0,
				"spawn_y": 5.0,
				"rested_pool": 0,  # T-360
				"rested_logout_at": 0,  # T-360
				"coins": 100,  # T-610: mirrors the schema default the CTE below ledgers
			}
			_test_inventory[character_id] = []
			_test_quests[character_id] = []
			CoinLedger.record(character_id, 100, CoinLedger.REASON_STARTING_GRANT)  # T-610 parity
		return true

	# T-610: the statement lives with the ledger — its seed CTE grants the starting coins
	# atomically with the character INSERT, so the faucet audit reconciles from birth.
	return _execute(CoinLedger.BOOTSTRAP_CHARACTER_INSERT_SQL, [username])


# T-507 identity pivot: the lookup key is the character NAME (unique among live characters).
# Pre-migration characters have name == account username, so every legacy caller/flow is intact.
static func get_character(name: String) -> Dictionary:
	if _test_skip_db:
		var row: Dictionary = _test_characters.get(name, {})
		return {} if bool(row.get("deleted", false)) else row

	var rows := _query(
		(
			"SELECT id, username, name, slot, class, class_locked, gender, xp, level, "
			+ "spawn_x, spawn_y, chosen_title, name_chosen "
			+ "FROM chars.characters WHERE name = $1 AND deleted_at IS NULL"
		),
		[name]
	)
	return rows[0] if not rows.is_empty() else {}


static func get_character_by_id(character_id: int) -> Dictionary:
	if _test_skip_db:
		for name: String in _test_characters:
			var row: Dictionary = _test_characters[name]
			if int(row.get("id", -1)) == character_id and not bool(row.get("deleted", false)):
				return row
		return {}

	var rows := _query(
		(
			"SELECT id, username, name, slot, class, class_locked, gender, xp, level, "
			+ "spawn_x, spawn_y, chosen_title, name_chosen "
			+ "FROM chars.characters WHERE id = $1 AND deleted_at IS NULL"
		),
		[character_id]
	)
	return rows[0] if not rows.is_empty() else {}


# T-507: backend seam for character_roster.gd (test-mode flag + shared fake store), mirroring
# the db_query/db_execute bridge — one test store, so roster and gameplay reads always agree.
static func test_mode() -> bool:
	return _test_skip_db


static func test_characters_ref() -> Dictionary:
	return _test_characters


# T-061: combat-facing view — class, level, and the per-class stat vector the world drives combat
# from (the L67 fix). T-064: stat_add talents layer on here; T-060: XP-bar fields are peer-only.
# T-399: equipped-gear stats fold into the SAME vector at this ONE point (see below). {} if unknown.
static func get_character_combat(
	username: String, talent_defs: Dictionary = {}, item_stats: Dictionary = {}
) -> Dictionary:
	var character: Dictionary = get_character(username)
	if character.is_empty():
		return {}
	var char_class: String = str(character.get("class", "warrior"))
	var level: int = int(character.get("level", 1))
	var cid: int = int(character.get("id", -1))
	var spent: Dictionary = get_talents(cid)
	var prog: Dictionary = _LV.progress(level, int(character.get("xp", 0)))
	var base_stats: Dictionary = _TL.apply_stat_mods(
		_LV.stats_for_level(char_class, level), spent, talent_defs
	)
	# T-399: fold gear into the base via T-364's broken-gear reader (0-durability = nothing).
	var stats: Dictionary = Durability.fold_equipped_into_stats(
		base_stats,
		get_inventory(cid),
		ServicesStore.get_durability(cid),
		func(item_id: String) -> Dictionary: return item_stats.get(item_id, {})
	)
	return {
		"class": char_class,
		"class_locked": _is_truthy(character.get("class_locked", false)),  # T-065
		"gender": str(character.get("gender", "")),  # T-520: "" until chosen -> client shows the panel
		"name": str(character.get("name", "")),  # T-716: the live character name (nameplate/roster)
		# T-716: false ONLY for a bootstrap character still owing the in-world name step (the client
		# shows the name modal after class). Defaults TRUE so a degraded read never re-asks.
		"name_chosen": _is_truthy(character.get("name_chosen", true)),
		"level": level,
		"xp_into_level": prog["xp_into_level"],
		"xp_for_next_level": prog["xp_for_next_level"],
		# T-360: banked rested pool -> the XP bar renders the rested band (peer-only, like XP).
		"rested_remaining": get_rested_remaining(cid),
		"stats": stats,
		"talents": spent,
		# T-712: the level-up banner's "Talent point earned (N)" — N is talent_logic's
		# points_available truth, computed here (the authority) so the client never mirrors the rule.
		"talent_points": _TL.points_available(level),
		"chosen_title": str(character.get("chosen_title", "")),  # T-401: worn title -> nameplate seed
		# T-550: ACCOUNT onboarding (tutorial graduation + hints seen) rides the spawn payload; load()
		# breaks the store<->manager preload cycle (the session_manager Database idiom).
		"account_onboarding":
		load("res://scripts/onboarding_store.gd").account_state(str(character.get("username", ""))),
	}


# T-035: grant XP + apply leveling. Returns {level, xp, leveled_up, levels_gained, rested_bonus,
# rested_remaining} or {} if unknown. T-360: body lives in rested_persist.apply_award (the banked
# pool boosts the award, draining 1:1 with the boosted base; `amount` unchanged so the ledger
# faucet is intact). T-358: `use_rested` follows the WoW rule — rested boosts MOB-KILL XP (default
# true) but NOT quest turn-in XP (the caller passes false); grinding drains rest, questing does not.
static func award_xp_to_character(
	character_id: int, amount: int, use_rested: bool = true
) -> Dictionary:
	return _RP.apply_award(
		character_id, amount, use_rested, _test_skip_db, _test_characters, _query, _execute
	)


static func award_xp(name: String, amount: int) -> bool:
	if _test_skip_db:
		if not _test_characters.has(name):
			return false
		var character: Dictionary = _test_characters[name]
		character["xp"] = int(character["xp"]) + amount
		_test_characters[name] = character
		return true

	return _execute(
		"UPDATE chars.characters SET xp = xp + $1 WHERE name = $2 AND deleted_at IS NULL",
		[amount, name]
	)


# ---- T-360: Rested XP (thin delegators; math+config+SQL live in rested_persist.gd) ----
# The world calls accrue_rested_on_login at spawn (bank the offline window) and mark_rested_logout
# on disconnect (stamp the window start); `now_unix` is injected so the flow stays deterministic.


static func accrue_rested_on_login(character_id: int, now_unix: int) -> int:
	return _RP.accrue_on_login(
		character_id, now_unix, _test_skip_db, _test_characters, _query, _execute
	)


static func mark_rested_logout(character_id: int, now_unix: int) -> void:
	_RP.mark_logout(character_id, now_unix, _test_skip_db, _test_characters, _execute)


static func get_rested_remaining(character_id: int) -> int:
	return _RP.remaining(character_id, _test_skip_db, _test_characters, _query)


# T-414: cap-clamped comfort-food rested grant (consumable use_item effect).
static func grant_rested(character_id: int, amount: int) -> int:
	return _RP.grant_pool(character_id, amount, _test_skip_db, _test_characters, _query, _execute)


static func get_inventory(character_id: int) -> Array:
	if _test_skip_db:
		return _test_inventory.get(character_id, [])

	# T-353: hydrate strips NULL rift-carry marks so untouched rows read as they did pre-migration.
	return _IP.hydrate(_query(_IP.select_sql(), [character_id]))


static func add_item_to_bag(
	character_id: int, item_id: String, count: int, slot_index: int
) -> bool:
	return _ID.add_to_bag(
		character_id, item_id, count, slot_index, _test_skip_db, _test_inventory, _execute
	)


static func remove_item(character_id: int, slot_type: String, slot_index: int) -> bool:
	return _ID.remove(character_id, slot_type, slot_index, _test_skip_db, _test_inventory, _execute)


# ---- T-036: server-authoritative inventory ops ---------------------------
# inventory_logic is the pure authority; these read the server-held inventory, run it, and persist
# its decision. item_registry is injected (lives in server/world, T-031). Each returns
# {ok, reason, slots}; nothing persists on failure. World->master routing is T-037/T-039.


# reward_items: Array of {item, count} (quest reward shape) OR {item_id, count}.
static func try_add_items(
	character_id: int, reward_items: Array, item_registry: Dictionary
) -> Dictionary:
	var additions: Array = []
	for entry: Dictionary in reward_items:
		(
			additions
			. append(
				{
					"item_id": str(entry.get("item_id", entry.get("item", ""))),
					"count": int(entry.get("count", 1)),
				}
			)
		)
	# T-701: this read IS the persisted pre-image (single writer) — pass it through so the persist
	# writes only the touched rows. Same one read as before; _IL never mutates its input.
	var prev := get_inventory(character_id)
	var result := _IL.add_items(prev, additions, item_registry)
	var appearance_unlocks := _IP.wearable_appearance_ids(additions, item_registry)
	result["appearance_unlocks"] = appearance_unlocks if result["ok"] else []
	if result["ok"]:
		_persist_inventory(character_id, result["slots"], appearance_unlocks, prev)
	return result


static func try_equip(
	character_id: int, bag_slot_index: int, item_registry: Dictionary
) -> Dictionary:
	# T-063: resolve the character's class server-side (never client-trusted) for the armor gate.
	# T-681: same read, same authority, for the equip-level gate — the persisted `level` column.
	var character := get_character_by_id(character_id)
	var char_class := str(character.get("class", ""))
	var char_level := int(character.get("level", 1))
	var prev := get_inventory(character_id)  # T-701: pre-image for the delta persist
	var result := _IL.equip(prev, bag_slot_index, item_registry, char_class, char_level)
	if result["ok"]:
		_persist_inventory(character_id, result["slots"], [], prev)
	return result


static func try_unequip(character_id: int, equip_slot_type: String) -> Dictionary:
	var prev := get_inventory(character_id)  # T-701: pre-image for the delta persist
	var result := _IL.unequip(prev, equip_slot_type)
	if result["ok"]:
		_persist_inventory(character_id, result["slots"], [], prev)
	return result


static func try_remove_item(
	character_id: int, slot_type: String, slot_index: int, count: int
) -> Dictionary:
	var prev := get_inventory(character_id)  # T-701: pre-image for the delta persist
	var result := _IL.remove(prev, slot_type, slot_index, count)
	if result["ok"]:
		_persist_inventory(character_id, result["slots"], [], prev)
	return result


# Replace the character's whole slot set (single writer). T-069: delete-all + reinsert is one
# transaction (errors roll back). T-567: returns whether it committed so the reward path can gate.
# T-701: a caller holding the persisted pre-image passes it as `previous_slots` and only the
# touched rows are written (T-700 delta; property-proven identical end-state). null = full write.
static func _persist_inventory(
	character_id: int, slots: Array, appearance_unlocks: Array = [], previous_slots: Variant = null
) -> bool:
	# Equipping is a learn point (starter/legacy gear); acquisition paths pass wearable ids explicitly.
	var unlocks := appearance_unlocks.duplicate()
	for entry: Dictionary in slots:
		if str(entry.get("slot_type", "")) in _IL.EQUIP_SLOTS:
			var equipped_id := str(entry.get("item_id", ""))
			if equipped_id != "" and not equipped_id in unlocks:
				unlocks.append(equipped_id)
	if _test_skip_db:
		if _test_fail_persist:  # T-567: injects a rolled-back write for the atomic-reject regression
			return false
		_test_inventory[character_id] = slots.duplicate(true)
		var owned: Array = _test_cosmetic_unlocks.get(character_id, [])
		for appearance_id: String in unlocks:
			if not appearance_id in owned:
				owned.append(appearance_id)
		_test_cosmetic_unlocks[character_id] = owned
		return true

	# T-353: statement builder lives in inventory_persist.gd (1000-line cap); master keeps _execute.
	var b: Dictionary = (
		_IP.build_persist_delta(character_id, previous_slots, slots, unlocks)
		if previous_slots is Array
		else _IP.build_persist(character_id, slots, unlocks)
	)
	if _execute(str(b["sql"]), b["params"]):
		return true
	printerr("[character_manager] inventory persist ROLLED BACK for char %d" % character_id)
	return false


# T-353: the rift gear-carry — runs the pure era_gear re-scale over the crossing character's
# inventory and persists the marked slots. `rarities` is world-injected (items.json lives
# cross-project). Returns {carried, retired} — the master half of the enter_era GEAR-CARRY HOOK.
static func carry_gear_across_era(
	character_id: int, target_era: int, rarities: Dictionary
) -> Dictionary:
	var result := _EG.carry(get_inventory(character_id), target_era, rarities)
	_persist_inventory(character_id, result["slots"])
	return {"carried": result["carried"], "retired": result["retired"]}


static func get_quests(character_id: int) -> Array:
	if _test_skip_db:
		return _test_quests.get(character_id, [])

	return _query(
		(
			"SELECT quest_id, state, accepted_at, completed_at, abandoned_at "
			+ "FROM chars.character_quests WHERE character_id = $1"
		),
		[character_id]
	)


static func accept_quest(character_id: int, quest_id: String) -> bool:
	if _test_skip_db:
		var quests: Array = _test_quests.get(character_id, [])
		for entry: Dictionary in quests:
			if entry["quest_id"] == quest_id:
				# T-293: re-accept resets an existing row to active (a repeatable bounty; the SM
				# already gated whether re-accept is legal). Objectives are re-zeroed by the caller.
				entry["state"] = "active"
				entry["accepted_at"] = "now"
				entry["completed_at"] = null
				entry["abandoned_at"] = null
				return true
		(
			quests
			. append(
				{
					"quest_id": quest_id,
					"state": "active",
					"accepted_at": "now",
					"completed_at": null,
					"abandoned_at": null,
				}
			)
		)
		_test_quests[character_id] = quests
		return true

	# T-293: ON CONFLICT DO UPDATE so a repeatable quest re-accepted after completion flips back to
	# active with a fresh accepted_at (the SM gated legality; a live active row can't reach here).
	return _execute(
		(
			"INSERT INTO chars.character_quests (character_id, quest_id, state) "
			+ "VALUES ($1,$2,'active') ON CONFLICT (character_id, quest_id) "
			+ "DO UPDATE SET state='active', accepted_at=NOW(), completed_at=NULL, abandoned_at=NULL"
		),
		[character_id, quest_id]
	)


# TD-003: an atomic CLAIM — only an ACTIVE quest completes, exactly one caller wins. Returns false
# when it was already complete/missing (0 rows claimed), so concurrent turn-ins never double-pay.
static func complete_quest(character_id: int, quest_id: String) -> bool:
	if _test_skip_db:
		for entry: Dictionary in _test_quests.get(character_id, []):
			if entry["quest_id"] == quest_id and str(entry.get("state", "")) == "active":
				return _set_quest_state(character_id, quest_id, "complete", "completed_at")
		return false

	var rows := _query(
		(
			"UPDATE chars.character_quests SET state='complete', completed_at=NOW() "
			+ "WHERE character_id=$1 AND quest_id=$2 AND state='active' RETURNING quest_id"
		),
		[character_id, quest_id]
	)
	# Defensive value match (not a row count): a stray psql line must never fake a claim.
	for row: Dictionary in rows:
		if str(row.get("quest_id", "")) == quest_id:
			return true
	return false


static func abandon_quest(character_id: int, quest_id: String) -> bool:
	# WoW behavior: abandoning REMOVES the quest entirely (log clears, giver's `!` returns, re-accept).
	if _test_skip_db:
		var kept: Array = []
		for entry: Dictionary in _test_quests.get(character_id, []):
			if entry["quest_id"] != quest_id:
				kept.append(entry)
		_test_quests[character_id] = kept
		var qmap: Dictionary = _test_objectives.get(character_id, {})
		qmap.erase(quest_id)
		_test_objectives[character_id] = qmap
		return true

	_execute(
		"DELETE FROM chars.character_quest_objectives WHERE character_id=$1 AND quest_id=$2",
		[character_id, quest_id]
	)
	return _execute(
		"DELETE FROM chars.character_quests WHERE character_id=$1 AND quest_id=$2",
		[character_id, quest_id]
	)


# ---- T-033: guarded quest transitions ------------------------------------
# quest_state_machine decides transition legality; these persist the effect only when it approves.
# Server facts (player_level, prereq_complete, objectives_complete, at_turnin_npc) are injected.


static func _quest_state(character_id: int, quest_id: String) -> String:
	for entry: Dictionary in get_quests(character_id):
		if str(entry.get("quest_id", "")) == quest_id:
			return str(entry.get("state", ""))
	return ""


# T-041: public accessor for a character's persisted quest state (RPC dispatch resolves prereqs).
static func quest_state(character_id: int, quest_id: String) -> String:
	return _quest_state(character_id, quest_id)


static func try_accept(
	character_id: int, quest: Dictionary, player_level: int, prereq_complete: bool
) -> _QSM.QuestResult:
	var quest_id: String = str(quest.get("id", ""))
	var result := _QSM.evaluate_accept(
		quest, _quest_state(character_id, quest_id), player_level, prereq_complete
	)
	if result.ok:
		# T-621: quest-log cap — refuse the 21st ACTIVE quest (already_active was rejected above).
		var active := 0
		for e: Dictionary in get_quests(character_id):
			active += 1 if str(e.get("state", "")) == _QSM.STATE_ACTIVE else 0
		if _QSM.would_exceed_log_cap(active):
			return _QSM.QuestResult.failure("log_full")
		accept_quest(character_id, quest_id)
		init_quest_objectives(character_id, quest)  # T-034: zero progress on accept
	return result


static func try_turn_in(
	character_id: int, quest: Dictionary, objectives_complete: bool, at_turnin_npc: bool
) -> _QSM.QuestResult:
	var quest_id: String = str(quest.get("id", ""))
	var result := _QSM.evaluate_turn_in(
		quest, _quest_state(character_id, quest_id), objectives_complete, at_turnin_npc
	)
	if result.ok:
		complete_quest(character_id, quest_id)
	return result


# T-043: atomic turn-in + reward grant ("all or none"): bag space pre-checked, then complete FIRST
# (blocks double turn-in), then persist + award XP. Returns a dict.
static func try_turn_in_with_rewards(
	character_id: int,
	quest: Dictionary,
	objectives_complete: bool,
	at_turnin_npc: bool,
	item_registry: Dictionary
) -> Dictionary:
	var quest_id := str(quest.get("id", ""))
	var guard := _QSM.evaluate_turn_in(
		quest, _quest_state(character_id, quest_id), objectives_complete, at_turnin_npc
	)
	if not guard.ok:
		return {"ok": false, "reason": guard.reason}

	var rewards: Dictionary = quest.get("rewards", {"xp": 0, "items": []})
	var additions: Array = []
	for it: Dictionary in rewards.get("items", []):
		(
			additions
			. append(
				{
					"item_id": str(it.get("item", it.get("item_id", ""))),
					"count": int(it.get("count", 1)),
				}
			)
		)

	# T-661 (#51): COLLECT-item consume BEFORE the bag-space check (opt out via "no_consume_items").
	var pre_slots: Array = get_inventory(character_id)
	if not bool(quest.get("no_consume_items", false)):
		pre_slots = _IL.remove_collect_objective_items(pre_slots, quest.get("objectives", []))
	# Bag-space pre-check (no persist): the reward must fit or the turn-in is rejected wholesale.
	var add_result := _IL.add_items(pre_slots, additions, item_registry)
	if not add_result["ok"]:
		return {"ok": false, "reason": add_result["reason"]}

	# TD-003: the atomic claim (active->complete) comes FIRST — blocks the double-grant TOCTOU.
	if not complete_quest(character_id, quest_id):
		return {"ok": false, "reason": "already_turned_in"}
	# T-567: reward items must ACTUALLY persist — a failed persist reopens the quest (no XP, no item).
	if not _persist_inventory(
		character_id, add_result["slots"], _IP.wearable_appearance_ids(additions, item_registry)
	):
		_set_quest_state(character_id, quest_id, "active", "completed_at")
		return {"ok": false, "reason": "reward_grant_failed"}
	# T-621: over-level decay (full to questLevel+5, then 80/60/40/20/10%; questLevel == min_level) —
	# per character, grouping never cuts quest XP. T-358: quest XP skips rested (use_rested=false).
	var char_level := int(get_character_by_id(character_id).get("level", 1))
	var xp := _QXP.decayed_xp(int(rewards.get("xp", 0)), char_level, int(quest.get("min_level", 1)))
	var leveling: Dictionary = award_xp_to_character(character_id, xp, false) if xp > 0 else {}
	return {"ok": true, "reason": "", "xp": xp, "leveling": leveling, "items": additions}


# ---- T-058: quest-provided items (granted on accept, removed on abandon/turn-in) ----


static func grant_provided_items(
	character_id: int, quest: Dictionary, item_registry: Dictionary
) -> Dictionary:
	var provided: Array = quest.get("provided_items", [])
	if provided.is_empty():
		return {"ok": true}
	return try_add_items(character_id, provided, item_registry)


static func remove_provided_items(character_id: int, quest: Dictionary) -> void:
	var provided: Array = quest.get("provided_items", [])
	if provided.is_empty():
		return
	_persist_inventory(character_id, _IL.remove_item_ids(get_inventory(character_id), provided))


static func try_abandon(character_id: int, quest_id: String) -> _QSM.QuestResult:
	var result := _QSM.evaluate_abandon(_quest_state(character_id, quest_id))
	if result.ok:
		abandon_quest(character_id, quest_id)
	return result


# ---- T-034: per-objective progress ---------------------------------------
# The objective_tracker is the pure authority; master persists its output. Credit is fed by
# server-observed events (kill/talk/reach) and inventory snapshots (collect). objectives_complete
# is the fact try_turn_in (T-033) consumes. The world->master RPC that calls credit_objective on
# a real kill, and resolving mob_type aliases, is T-037.


static func init_quest_objectives(character_id: int, quest: Dictionary) -> void:
	_persist_objectives(
		character_id, str(quest.get("id", "")), _OT.zeros(quest.get("objectives", []))
	)


static func get_objective_progress(character_id: int, quest_id: String) -> Array:
	if _test_skip_db:
		return _test_objectives.get(character_id, {}).get(quest_id, [])

	var rows := _query(
		(
			"SELECT progress FROM chars.character_quest_objectives "
			+ "WHERE character_id = $1 AND quest_id = $2 ORDER BY objective_index"
		),
		[character_id, quest_id]
	)
	var out: Array = []
	for row: Dictionary in rows:
		out.append(int(row.get("progress", 0)))
	return out


static func credit_objective(
	character_id: int, quest: Dictionary, kind: String, target: String
) -> void:
	var quest_id: String = str(quest.get("id", ""))
	var objectives: Array = quest.get("objectives", [])
	var current: Array = get_objective_progress(character_id, quest_id)
	if current.is_empty():
		current = _OT.zeros(objectives)
	_persist_objectives(character_id, quest_id, _OT.credit_event(objectives, current, kind, target))


static func refresh_collect(character_id: int, quest: Dictionary, item_counts: Dictionary) -> void:
	var quest_id: String = str(quest.get("id", ""))
	var objectives: Array = quest.get("objectives", [])
	var current: Array = get_objective_progress(character_id, quest_id)
	if current.is_empty():
		current = _OT.zeros(objectives)
	_persist_objectives(character_id, quest_id, _OT.apply_collect(objectives, current, item_counts))


# T-045: recompute every active quest's `collect` objectives from the character's current bag counts
# (snapshot — may decrease). Run after any inventory change. Returns the refreshed quest ids.
# T-058: one quest's raw persisted row + progress ({} when the quest is gone — abandoned).
static func quest_entry(character_id: int, quest_id: String) -> Dictionary:
	for entry: Dictionary in get_quests(character_id):
		if str(entry.get("quest_id", "")) == quest_id:
			var out: Dictionary = entry.duplicate()
			out["progress"] = get_objective_progress(character_id, quest_id)
			return out
	return {}


static func refresh_collect_for_character(character_id: int, quest_defs: Dictionary) -> Array:
	var counts: Dictionary = _IL.bag_item_counts(get_inventory(character_id))
	var refreshed: Array = []
	for entry: Dictionary in get_quests(character_id):
		if str(entry.get("state", "")) != "active":
			continue
		var quest_id := str(entry.get("quest_id", ""))
		if not quest_defs.has(quest_id):
			continue
		var quest: Dictionary = quest_defs[quest_id]
		if _has_collect_objective(quest):
			refresh_collect(character_id, quest, counts)
			refreshed.append(quest_id)
	return refreshed


static func _has_collect_objective(quest: Dictionary) -> bool:
	for obj: Dictionary in quest.get("objectives", []):
		if str(obj.get("type", "")) == "collect":
			return true
	return false


static func objectives_complete(character_id: int, quest: Dictionary) -> bool:
	var progress: Array = get_objective_progress(character_id, str(quest.get("id", "")))
	return _OT.is_complete(quest.get("objectives", []), progress)


# T-046: credit a server-observed event (kind/target) to every ACTIVE quest of the character whose
# world-supplied def has a matching objective — the generalized core behind credit_kill (T-042,
# mob_death resolved server-side, T-026/T-034) and credit_reach. Returns {"credited": [quest_id]}.
static func credit_event(
	character_id: int, kind: String, target: String, quest_defs: Dictionary
) -> Dictionary:
	var credited: Array = []
	for entry: Dictionary in get_quests(character_id):
		if str(entry.get("state", "")) != "active":
			continue
		var quest_id := str(entry.get("quest_id", ""))
		if not quest_defs.has(quest_id):
			continue
		var quest: Dictionary = quest_defs[quest_id]
		if _has_objective(quest, kind, target):
			credit_objective(character_id, quest, kind, target)
			credited.append(quest_id)
	return {"credited": credited}


static func credit_kill(character_id: int, mob_id: String, quest_defs: Dictionary) -> Dictionary:
	return credit_event(character_id, "kill", mob_id, quest_defs)


# T-046: server-observed reach (player entered a reach objective's radius — resolved world-side).
static func credit_reach(character_id: int, target: String, quest_defs: Dictionary) -> Dictionary:
	return credit_event(character_id, "reach", target, quest_defs)


static func _has_objective(quest: Dictionary, kind: String, target: String) -> bool:
	# T-426: _OT.target_matches lets a "*" objective target match any event target of this kind.
	for obj: Dictionary in quest.get("objectives", []):
		if str(obj.get("type", "")) == kind and _OT.target_matches(str(obj["target"]), target):
			return true
	return false


# T-046: per-player !/? indicator for each NPC (aggregates T-037's npc_state_for_character). npcs is
# an Array of {id, gives_quests, talk_text}; quest_defs the relevant defs → {npc_id: indicator}.
static func npc_indicators(character_id: int, npcs: Array, quest_defs: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for npc: Dictionary in npcs:
		out[str(npc.get("id", ""))] = npc_state_for_character(character_id, npc, quest_defs)["indicator"]
	return out


# ---- T-037: NPC quest givers — indicators + talk ------------------------
# npc_interaction is the pure authority on the `!`/`?` indicator and talk plan; these methods build
# its facts from persisted quest state (reusing the T-033 state machine + T-034 tracker) and persist
# the talk credit. NPC + quest defs are injected (the T-036 cross-project seam); the world supplies
# them when the talk RPC is wired (out of scope here, like the quest RPC every M2 ticket deferred).


# Computes the per-player indicator/available/turn_in_ready/talk_targets for one NPC.
static func npc_state_for_character(
	character_id: int, npc: Dictionary, quest_defs: Dictionary
) -> Dictionary:
	var level := int(get_character_by_id(character_id).get("level", 1))
	var facts: Dictionary = {}
	for quest_id: String in quest_defs:
		var quest: Dictionary = quest_defs[quest_id]
		var prereq := str(quest.get("prerequisite_quest", ""))
		var prereq_complete := prereq == "" or _quest_state(character_id, prereq) == "complete"
		facts[quest_id] = {
			"state": _quest_state(character_id, quest_id),
			"player_level": level,
			"prereq_complete": prereq_complete,
			"objectives_complete": objectives_complete(character_id, quest),
		}
	return _NI.evaluate(npc, quest_defs, facts)


# Server-authoritative talk: credit any active `talk` objective for this NPC (T-034), then recompute
# the indicator (a credited talk may complete objectives → flip to `?`). Returns the post-talk npc
# state plus {"talk_text", "credited": [quest_id]}.
static func npc_talk(character_id: int, npc: Dictionary, quest_defs: Dictionary) -> Dictionary:
	var npc_id := str(npc.get("id", ""))
	var before := npc_state_for_character(character_id, npc, quest_defs)
	for quest_id: String in before["talk_targets"]:
		credit_objective(character_id, quest_defs[quest_id], "talk", npc_id)
	var after := npc_state_for_character(character_id, npc, quest_defs)
	after["talk_text"] = str(npc.get("talk_text", ""))
	after["credited"] = before["talk_targets"]
	return after


static func _persist_objectives(character_id: int, quest_id: String, progress: Array) -> void:
	if _test_skip_db:
		var qmap: Dictionary = _test_objectives.get(character_id, {})
		qmap[quest_id] = progress
		_test_objectives[character_id] = qmap
		return

	# T-069: one transactional script (was one psql subprocess per objective row).
	var params: Array = []
	var stmts: Array = ["BEGIN;"]
	for index in range(progress.size()):
		var base: int = params.size()
		params.append_array([character_id, quest_id, index, int(progress[index])])
		stmts.append(
			(
				(
					"INSERT INTO chars.character_quest_objectives "
					+ "(character_id, quest_id, objective_index, progress) "
					+ "VALUES ($%d,$%d,$%d,$%d) "
					+ "ON CONFLICT (character_id, quest_id, objective_index) "
					+ "DO UPDATE SET progress = EXCLUDED.progress;"
				)
				% [base + 1, base + 2, base + 3, base + 4]
			)
		)
	stmts.append("COMMIT;")
	if not _execute("\n".join(stmts), params):
		printerr(
			(
				"[character_manager] objective persist ROLLED BACK for char %d quest %s"
				% [character_id, quest_id]
			)
		)


# T-065: Postgres TSV booleans arrive as "t"/"f" strings; test mode stores real bools.
static func _is_truthy(v) -> bool:
	if v is bool:
		return v
	return str(v) == "t" or str(v) == "true"


# T-065/T-520 carve: the one-shot creation choices live in creation_choice.gd (character_manager is
# AT the 1000-line cap). These thin delegators resolve the row then inject the backend seam
# (test flag + test-store ref + _execute Callable), mirroring the rested_persist delegation.
static func set_class(character_id: int, char_class: String) -> Dictionary:
	return _CRE.set_class(
		get_character_by_id(character_id), char_class, _test_skip_db, _test_characters, _execute
	)


static func set_gender(character_id: int, gender: String) -> Dictionary:
	return _CRE.set_gender(
		get_character_by_id(character_id), gender, _test_skip_db, _test_characters, _execute
	)


# T-716: the in-world name step. Takes _query (not _execute) because its guarded UPDATE has to know
# whether a ROW changed — a lost uniqueness race is the difference between "named" and "name_taken".
static func set_character_name(character_id: int, name: String) -> Dictionary:
	return _CRE.set_character_name(
		get_character_by_id(character_id), name, _test_skip_db, _test_characters, _query
	)


# T-319: guarantee the character has an equipped starting weapon for its class (rides the T-225
# gear broadcast to every client). Idempotent — a character already holding ANY weapon (starter
# or looted) is untouched, and an UNCLASSED character is skipped (client placeholder covers it).
static func ensure_starting_weapon(character_id: int) -> Dictionary:
	var character: Dictionary = get_character_by_id(character_id)
	if character.is_empty():
		return {"granted": false, "slots": []}
	var slots: Array = get_inventory(character_id)
	if not _is_truthy(character.get("class_locked", false)):
		return {"granted": false, "slots": slots}
	var updated: Array = _SG.with_starting_weapon(slots, str(character.get("class", "warrior")))
	if updated.size() == slots.size():
		return {"granted": false, "slots": slots}
	_persist_inventory(character_id, updated)
	return {"granted": true, "slots": updated}


# ---- T-064: talents (spend validation is pure in talent_logic; this persists) ----


static func get_talents(character_id: int) -> Dictionary:
	if _test_skip_db:
		return _test_talents.get(character_id, {})
	var out: Dictionary = {}
	var rows := _query(
		"SELECT talent_id, ranks FROM chars.character_talents WHERE character_id = $1",
		[character_id]
	)
	for row: Dictionary in rows:
		out[str(row.get("talent_id", ""))] = int(row.get("ranks", 0))
	return out


# Spend ONE point in `talent` (def supplied by the world, the content authority).
# Returns {ok, reason, ranks, points_left}.
static func spend_talent(
	character_id: int, talent: Dictionary, talent_defs: Dictionary
) -> Dictionary:
	var character: Dictionary = get_character_by_id(character_id)
	if character.is_empty():
		return {"ok": false, "reason": "unknown_character", "ranks": 0, "points_left": 0}
	var spent: Dictionary = get_talents(character_id)
	var level: int = int(character.get("level", 1))
	var verdict: Dictionary = _TL.validate_spend(
		talent, spent, talent_defs, str(character.get("class", "")), level
	)
	var talent_id: String = str(talent.get("id", ""))
	if not verdict["ok"]:
		return {
			"ok": false,
			"reason": verdict["reason"],
			"ranks": int(spent.get(talent_id, 0)),
			"points_left": _TL.points_available(level) - _TL.points_spent(spent),
		}
	var new_ranks: int = int(spent.get(talent_id, 0)) + 1
	if _test_skip_db:
		spent[talent_id] = new_ranks
		_test_talents[character_id] = spent
	else:
		_execute(
			(
				"INSERT INTO chars.character_talents (character_id, talent_id, ranks) "
				+ "VALUES ($1,$2,1) ON CONFLICT (character_id, talent_id) "
				+ "DO UPDATE SET ranks = chars.character_talents.ranks + 1"
			),
			[character_id, talent_id]
		)
		spent[talent_id] = new_ranks
	return {
		"ok": true,
		"reason": "",
		"ranks": new_ranks,
		"points_left": _TL.points_available(level) - _TL.points_spent(spent),
	}


# T-064: reroll path — talents die with the old build (no respec; delete wholesale).
static func clear_talents(character_id: int) -> bool:
	if _test_skip_db:
		_test_talents.erase(character_id)
		return true
	return _execute("DELETE FROM chars.character_talents WHERE character_id = $1", [character_id])


# T-567: DB path added so the reward-grant reopen shares one state writer; completed_at is stamped
# only on completion (cleared otherwise) so a reopened quest carries no stale completion time.
static func _set_quest_state(
	character_id: int, quest_id: String, state: String, timestamp_key: String
) -> bool:
	if not _test_skip_db:
		return _execute(
			(
				"UPDATE chars.character_quests SET state=$3, "
				+ "completed_at = CASE WHEN $3 = 'complete' THEN NOW() ELSE NULL END "
				+ "WHERE character_id=$1 AND quest_id=$2"
			),
			[character_id, quest_id, state]
		)
	var quests: Array = _test_quests.get(character_id, [])
	for entry: Dictionary in quests:
		if entry["quest_id"] == quest_id:
			entry["state"] = state
			entry[timestamp_key] = "now"
			_test_quests[character_id] = quests
			return true
	return false


# T-701 carve: pure delegation to db_bridge.gd — kept because internal callers and the extracted
# modules (rested_persist / creation_choice / inventory_direct) bind these as Callables.
static func _execute(sql: String, parameters: Array) -> bool:
	return _DB.execute(sql, parameters)


static func _query(sql: String, parameters: Array) -> Array:
	return _DB.query(sql, parameters)


# ---- T-208: vault moves (slot_type 'vault' rides inventory.character_items) --
# T-507 carve: body moved to inventory_direct.gd (this file was back at the 1000-line cap).


static func apply_vault_move(character_id: int, plan: Dictionary) -> bool:
	return _ID.vault_move(character_id, plan, _test_skip_db, _test_inventory, _execute)


# T-208: public DB bridge for ServicesStore (split out for the file-size budget; one
# connection idiom, one place to swap the driver).
static func db_execute(sql: String, parameters: Array) -> bool:
	return _execute(sql, parameters)


static func db_query(sql: String, parameters: Array) -> Array:
	return _query(sql, parameters)
