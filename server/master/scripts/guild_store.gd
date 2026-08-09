class_name GuildStore
extends RefCounted

# T-362: persisted player guilds (chars.guilds + chars.guild_members, migration 014). Same test-mode
# discipline as SocialStore/ServicesStore — CharacterManager.reset_for_test() chains into
# reset_for_test() here, and DB plumbing rides character_manager's db_query/db_execute.
#
# Server-authority notes (the whole point):
#   - The WORLD resolves the ACTING username from the live session; the target of invite/kick/
#     promote is resolved HERE against the character table (the client can't inject an id).
#   - Every management verb is gated by the actor's PERSISTED rank through GuildLogic. There is NO
#     op that grants rank or membership by client assertion; you get a rank by being promoted by
#     someone who already outranks you, and you get membership only by accepting a pending invite.
#   - Pending invites are ephemeral (in-memory, like trade sessions) — an offline-issued invite that
#     the target never accepts simply evaporates; nothing durable moves until accept.

const _CM := preload("res://scripts/character_manager.gd")
const _SS := preload("res://scripts/services_store.gd")
const GuildLogic := preload("res://scripts/guild_logic.gd")
const GuildAchievements := preload("res://scripts/guild_achievement_store.gd")  # T-679 trophy wall
const GuildBank := preload("res://scripts/guild_bank_store.gd")  # T-683 shared coin/item vault

# Founding cost — a copper sink (ties T-366). Debited from the founder on create; refunded to nobody
# on disband (classic MMO behaviour — the sink is the point).
const CREATE_COST := 1000

static var _test_guilds: Dictionary = {}  # gid -> {id, name, leader_id}
static var _test_members: Dictionary = {}  # cid -> {guild_id, rank}
static var _invites: Dictionary = {}  # target_cid -> guild_id (ephemeral, both modes)
static var _next_gid: int = 1


static func reset_for_test() -> void:
	_test_guilds.clear()
	_test_members.clear()
	_invites.clear()
	_next_gid = 1
	GuildBank.reset_for_test()  # T-683: pooled coin/item vault fakes


# Single entry point (master main dispatch). params: {username, action, name?, target_name?}.
# actions: create|invite|accept|decline|leave|kick|promote|demote|disband|roster|browse|
# set_recruitment. Browsing is public; editing uses the same persisted can_invite rank gate.
# Every successful mutation returns the fresh roster (+ action-specific keys) so the world/client
# never guess at state.
static func op(params: Dictionary) -> Dictionary:
	# T-679: a server-to-server presence tick (the world's authoritative online snapshot) carries no
	# acting character — it credits the guild directly, so it is handled BEFORE the actor lookup and
	# can never be reached by a client verb (the world resolves guild_id + count; the client cannot).
	if str(params.get("action", "")) == "note_presence":
		return _note_presence(int(params.get("guild_id", 0)), int(params.get("online_count", 0)))
	var actor := _CM.get_character(str(params.get("username", "")))
	if actor.is_empty():
		return {"error": "unknown_character"}
	var cid := int(actor["id"])
	var action := str(params.get("action", "roster"))
	match action:
		"create":
			return _create(cid, str(params.get("name", "")))
		"invite":
			return _invite(cid, str(params.get("target_name", "")))
		"accept":
			return _accept(cid)
		"decline":
			_invites.erase(cid)
			return {"ok": true, "declined": true}
		"leave":
			return _leave(cid)
		"kick":
			return _kick(cid, str(params.get("target_name", "")))
		"promote":
			return _rank_change(cid, str(params.get("target_name", "")), true)
		"demote":
			return _rank_change(cid, str(params.get("target_name", "")), false)
		"disband":
			return _disband(cid, params.get("item_registry", {}))
		"set_recruitment":
			return _set_recruitment(
				cid, bool(params.get("open", false)), str(params.get("blurb", ""))
			)
		"browse":
			return _browse_open()
		"roster":
			var m := _membership(cid)
			if m.is_empty():
				return {"error": "not_in_guild"}
			return _roster(int(m["guild_id"]))
		"achievements":
			# T-679: the read-only guild trophy wall for the acting member's guild. No grant path —
			# guild achievements are credited only by server-observed play (never a client verb).
			var m := _membership(cid)
			if m.is_empty():
				return {"error": "not_in_guild"}
			return GuildAchievements.list(int(m["guild_id"]))
		"bank_view", "bank_deposit", "bank_withdraw", "bank_deposit_item", "bank_withdraw_item":
			# T-683: the guild bank. Membership + PERSISTED rank are resolved HERE; GuildBank never
			# sees a client-asserted rank. Deposit is member-wide, withdraw is Officer+ (GuildLogic).
			return _bank_op(cid, action, params)
		_:
			return {"error": "unknown_action"}


# T-683: dispatch a bank verb with the actor's server-resolved guild_id + rank. The bank module owns
# the atomicity/ledger/cap; this only supplies the authority context the client cannot forge.
static func _bank_op(cid: int, action: String, params: Dictionary) -> Dictionary:
	var m := _membership(cid)
	if m.is_empty():
		return {"error": "not_in_guild"}
	var gid := int(m["guild_id"])
	var rank := int(m["rank"])
	var registry: Dictionary = params.get("item_registry", {})
	match action:
		"bank_view":
			return GuildBank.view(gid)
		"bank_deposit":
			return GuildBank.deposit_coins(cid, gid, rank, int(params.get("amount", 0)))
		"bank_withdraw":
			return GuildBank.withdraw_coins(cid, gid, rank, int(params.get("amount", 0)))
		"bank_deposit_item":
			return GuildBank.deposit_item(
				cid,
				gid,
				rank,
				int(params.get("slot_index", -1)),
				int(params.get("count", 0)),
				registry
			)
		"bank_withdraw_item":
			return GuildBank.withdraw_item(
				cid,
				gid,
				rank,
				str(params.get("item_id", "")),
				int(params.get("count", 0)),
				registry
			)
	return {"error": "unknown_action"}


# T-679: fold the world-computed count of guildmates currently online into the guild's
# "N members online together" milestone (guild_online is a MAX high-water mark, so a lower later
# count never lowers the peak, and re-ticks never double-credit). Ignores an unknown guild / a
# non-positive count. Returns the newly-earned defs so the world can toast the roster.
static func _note_presence(gid: int, online_count: int) -> Dictionary:
	if gid <= 0 or online_count <= 0:
		return {"ok": false}
	if not _CM._test_skip_db and _guild(gid).is_empty():
		return {"ok": false}
	var earned: Array = GuildAchievements.observe(gid, "guild_online", "*", online_count).get(
		"newly_earned", []
	)
	return {"ok": true, "guild_achievements": earned}


# ---- read helpers (also feed the world's guild-chat cache) ----------------------


# The acting character's guild id, or 0 — rides the get_character_combat spawn payload so the world
# seeds its guild-chat routing cache without a second round-trip.
static func guild_id_for(cid: int) -> int:
	var m := _membership(cid)
	return int(m.get("guild_id", 0)) if not m.is_empty() else 0


# Login/discovery truth carried to the world: empty for guildless characters. The client can never
# supply these fields; they are read from persisted membership + guild rows.
static func profile_for(cid: int) -> Dictionary:
	var m := _membership(cid)
	if m.is_empty():
		return {"guild_id": 0, "guild_name": "", "guild_rank": -1}
	var g := _guild(int(m["guild_id"]))
	if g.is_empty():
		return {"guild_id": 0, "guild_name": "", "guild_rank": -1}
	return {
		"guild_id": int(m["guild_id"]),
		"guild_name": str(g["name"]),
		"guild_rank": int(m["rank"]),
	}


static func _membership(cid: int) -> Dictionary:
	if _CM._test_skip_db:
		return _test_members.get(cid, {})
	var rows := _CM.db_query(
		"SELECT guild_id, rank FROM chars.guild_members WHERE character_id = $1", [cid]
	)
	if rows.is_empty():
		return {}
	return {"guild_id": int(rows[0]["guild_id"]), "rank": int(rows[0]["rank"])}


static func _guild(gid: int) -> Dictionary:
	if _CM._test_skip_db:
		return _test_guilds.get(gid, {})
	var rows := _CM.db_query(
		(
			"SELECT id, name, leader_id, recruitment_open, recruitment_blurb "
			+ "FROM chars.guilds WHERE id = $1"
		),
		[gid]
	)
	if rows.is_empty():
		return {}
	var r0: Dictionary = rows[0]
	return {
		"id": int(r0["id"]),
		"name": str(r0["name"]),
		"leader_id": int(r0["leader_id"]),
		"recruitment_open": _truthy(r0.get("recruitment_open", false)),
		"recruitment_blurb": str(r0.get("recruitment_blurb", "")),
	}


# {"guild_id","guild_name","members":[{name,rank,rank_name,is_leader}...]} — sorted rank then name.
static func _roster(gid: int) -> Dictionary:
	var g := _guild(gid)
	if g.is_empty():
		return {"error": "guild_gone"}
	var members: Array = []
	var rows := _member_rows(gid)
	for row in rows:
		var uname := str(_CM.get_character_by_id(int(row["character_id"])).get("name", ""))
		var rank := int(row["rank"])
		(
			members
			. append(
				{
					"name": uname,
					"rank": rank,
					"rank_name": GuildLogic.rank_name(rank),
					"is_leader": rank == GuildLogic.RANK_LEADER,
				}
			)
		)
	members.sort_custom(
		func(a, b):
			return (
				int(a["rank"]) < int(b["rank"])
				or (int(a["rank"]) == int(b["rank"]) and str(a["name"]) < str(b["name"]))
			)
	)
	return {
		"ok": true,
		"guild_id": gid,
		"guild_name": str(g["name"]),
		"members": members,
		"recruitment_open": bool(g.get("recruitment_open", false)),
		"recruitment_blurb": str(g.get("recruitment_blurb", "")),
	}


static func _member_rows(gid: int) -> Array:
	if _CM._test_skip_db:
		var out: Array = []
		for cid in _test_members:
			var m: Dictionary = _test_members[cid]
			if int(m["guild_id"]) == gid:
				out.append({"character_id": cid, "rank": int(m["rank"])})
		return out
	return _CM.db_query(
		"SELECT character_id, rank FROM chars.guild_members WHERE guild_id = $1", [gid]
	)


static func _name_taken(name: String) -> bool:
	if _CM._test_skip_db:
		for gid in _test_guilds:
			if str(_test_guilds[gid]["name"]).to_lower() == name.to_lower():
				return true
		return false
	var rows := _CM.db_query("SELECT id FROM chars.guilds WHERE lower(name) = lower($1)", [name])
	return not rows.is_empty()


# The psql TSV bridge returns booleans as "t"/"f" while test mode stores native bools.
static func _truthy(value: Variant) -> bool:
	if value is bool:
		return value
	return str(value) in ["t", "true"]


# ---- mutations ------------------------------------------------------------------


static func _create(cid: int, name: String) -> Dictionary:
	if not GuildLogic.valid_name(name):
		return {"error": "bad_name"}
	if not _membership(cid).is_empty():
		return {"error": "already_in_guild"}
	if _name_taken(name):
		return {"error": "name_taken"}
	if _SS.get_coins(cid) < CREATE_COST:
		return {"error": "insufficient_coins"}
	# Debit FIRST (fail-closed): if the coin move can't complete, no guild is born.
	if not _SS.adjust_coins(cid, -CREATE_COST, "guild_create"):  # T-366: coin sink
		return {"error": "insufficient_coins"}
	var gid := _insert_guild(name, cid)
	_set_member(cid, gid, GuildLogic.RANK_LEADER)
	var r := _roster(gid)
	r["created"] = true
	r["cost"] = CREATE_COST
	return r


static func _invite(cid: int, target_name: String) -> Dictionary:
	var m := _membership(cid)
	if m.is_empty():
		return {"error": "not_in_guild"}
	if not GuildLogic.can_invite(int(m["rank"])):
		return {"error": "no_permission"}
	var target := _CM.get_character(target_name)
	if target.is_empty():
		return {"error": "unknown_target"}
	var tid := int(target["id"])
	if tid == cid:
		return {"error": "self_target"}
	if not _membership(tid).is_empty():
		return {"error": "target_in_guild"}
	var gid := int(m["guild_id"])
	_invites[tid] = gid
	var g := _guild(gid)
	return {
		"ok": true,
		"invited": str(target.get("name", target_name)),
		"target_id": tid,
		"guild_id": gid,
		"guild_name": str(g.get("name", "")),
	}


static func _accept(cid: int) -> Dictionary:
	if not _invites.has(cid):
		return {"error": "no_invite"}
	var gid := int(_invites[cid])
	_invites.erase(cid)
	if not _membership(cid).is_empty():
		return {"error": "already_in_guild"}
	if _guild(gid).is_empty():
		return {"error": "guild_gone"}  # disbanded before accept
	_set_member(cid, gid, GuildLogic.RANK_MEMBER)
	var r := _roster(gid)
	r["joined"] = true
	return r


static func _leave(cid: int) -> Dictionary:
	var m := _membership(cid)
	if m.is_empty():
		return {"error": "not_in_guild"}
	if int(m["rank"]) == GuildLogic.RANK_LEADER:
		# The leader can't orphan a guild by leaving — they must disband (or, in a future ticket,
		# transfer the crown first). Fail-closed keeps the invariant "every guild has a leader".
		return {"error": "leader_must_disband"}
	_remove_member(cid)
	return {"ok": true, "left": true, "guild_id": int(m["guild_id"])}


static func _kick(cid: int, target_name: String) -> Dictionary:
	var m := _membership(cid)
	if m.is_empty():
		return {"error": "not_in_guild"}
	var target := _CM.get_character(target_name)
	if target.is_empty():
		return {"error": "unknown_target"}
	var tid := int(target["id"])
	var tm := _membership(tid)
	if tm.is_empty() or int(tm["guild_id"]) != int(m["guild_id"]):
		return {"error": "target_not_in_guild"}
	if not GuildLogic.can_kick(int(m["rank"]), int(tm["rank"])):
		return {"error": "no_permission"}
	_remove_member(tid)
	var r := _roster(int(m["guild_id"]))
	r["kicked"] = str(target.get("name", target_name))
	r["target_id"] = tid
	return r


static func _rank_change(cid: int, target_name: String, promote: bool) -> Dictionary:
	var m := _membership(cid)
	if m.is_empty():
		return {"error": "not_in_guild"}
	if not GuildLogic.can_promote(int(m["rank"])):
		return {"error": "no_permission"}  # leader-only
	var target := _CM.get_character(target_name)
	if target.is_empty():
		return {"error": "unknown_target"}
	var tid := int(target["id"])
	if tid == cid:
		return {"error": "self_target"}
	var tm := _membership(tid)
	if tm.is_empty() or int(tm["guild_id"]) != int(m["guild_id"]):
		return {"error": "target_not_in_guild"}
	var new_rank := (
		GuildLogic.promoted_rank(int(tm["rank"]))
		if promote
		else GuildLogic.demoted_rank(int(tm["rank"]))
	)
	_set_member(tid, int(m["guild_id"]), new_rank)
	var r := _roster(int(m["guild_id"]))
	r["target_id"] = tid
	return r


static func _disband(cid: int, params_registry: Dictionary = {}) -> Dictionary:
	var m := _membership(cid)
	if m.is_empty():
		return {"error": "not_in_guild"}
	if not GuildLogic.can_disband(int(m["rank"])):
		return {"error": "no_permission"}
	var gid := int(m["guild_id"])
	# Names (not ids) so the world can clear each online member's guild-chat cache + notify them.
	var member_names: Array = []
	for row in _member_rows(gid):
		member_names.append(str(_CM.get_character_by_id(int(row["character_id"])).get("name", "")))
	# T-683 DISBAND RULE: return the bank's coin + item stacks to the LEADER (the disbander) BEFORE
	# the guild row is deleted (the ON DELETE CASCADE would otherwise orphan the vault). Runs first
	# so nothing is lost; bag overflow forfeits as a documented sink (see resolve_on_disband).
	var bank := GuildBank.resolve_on_disband(gid, cid, params_registry)
	_delete_guild(gid)
	# Drop any pending invites into the now-dead guild so a later accept doesn't resurrect it.
	for tid in _invites.keys():
		if int(_invites[tid]) == gid:
			_invites.erase(tid)
	return {
		"ok": true,
		"disbanded": true,
		"guild_id": gid,
		"member_names": member_names,
		"bank": bank,  # T-683: {coins_returned, items_returned, items_forfeited} for the disband toast
	}


# T-451: persisted opt-in public listing. The blurb/open flag are desires from the client, but the
# actor's guild/rank are resolved here and checked through the existing invite authority gate.
static func _set_recruitment(cid: int, is_open: bool, blurb: String) -> Dictionary:
	var m := _membership(cid)
	if m.is_empty():
		return {"error": "not_in_guild"}
	if not GuildLogic.can_invite(int(m["rank"])):
		return {"error": "no_permission"}
	blurb = blurb.strip_edges()
	if not GuildLogic.valid_recruitment_blurb(blurb):
		return {"error": "bad_blurb"}
	var gid := int(m["guild_id"])
	if _CM._test_skip_db:
		_test_guilds[gid]["recruitment_open"] = is_open
		_test_guilds[gid]["recruitment_blurb"] = blurb
	else:
		_CM.db_execute(
			(
				"UPDATE chars.guilds SET recruitment_open = $1, recruitment_blurb = $2 "
				+ "WHERE id = $3"
			),
			[is_open, blurb, gid]
		)
	return _roster(gid)


# Public read: open guilds only, stable name order, with a server-counted roster size. This does
# not invite or join anyone; the normal rank-gated T-362 invite/accept flow remains the only path.
static func _browse_open() -> Dictionary:
	var guilds: Array = []
	if _CM._test_skip_db:
		for gid in _test_guilds:
			var g: Dictionary = _test_guilds[gid]
			if not bool(g.get("recruitment_open", false)):
				continue
			(
				guilds
				. append(
					{
						"guild_id": int(gid),
						"name": str(g["name"]),
						"blurb": str(g.get("recruitment_blurb", "")),
						"members": _member_rows(int(gid)).size(),
					}
				)
			)
	else:
		var rows := _CM.db_query(
			(
				"SELECT g.id, g.name, g.recruitment_blurb, COUNT(m.character_id) AS members "
				+ "FROM chars.guilds g LEFT JOIN chars.guild_members m ON m.guild_id = g.id "
				+ "WHERE g.recruitment_open = TRUE GROUP BY g.id, g.name, g.recruitment_blurb "
				+ "ORDER BY lower(g.name)"
			),
			[]
		)
		for row: Dictionary in rows:
			(
				guilds
				. append(
					{
						"guild_id": int(row["id"]),
						"name": str(row["name"]),
						"blurb": str(row.get("recruitment_blurb", "")),
						"members": int(row.get("members", 0)),
					}
				)
			)
	guilds.sort_custom(func(a, b): return str(a["name"]).to_lower() < str(b["name"]).to_lower())
	return {"ok": true, "guilds": guilds}


# ---- storage primitives (test-fake ↔ DB) ----------------------------------------


static func _insert_guild(name: String, leader_id: int) -> int:
	if _CM._test_skip_db:
		var gid := _next_gid
		_next_gid += 1
		_test_guilds[gid] = {
			"id": gid,
			"name": name,
			"leader_id": leader_id,
			"recruitment_open": false,
			"recruitment_blurb": "",
		}
		return gid
	var rows := _CM.db_query(
		"INSERT INTO chars.guilds (name, leader_id) VALUES ($1, $2) RETURNING id", [name, leader_id]
	)
	return int(rows[0]["id"]) if not rows.is_empty() else 0


static func _set_member(cid: int, gid: int, rank: int) -> void:
	if _CM._test_skip_db:
		_test_members[cid] = {"guild_id": gid, "rank": rank}
		return
	_CM.db_execute(
		(
			"INSERT INTO chars.guild_members (character_id, guild_id, rank) VALUES ($1, $2, $3) "
			+ "ON CONFLICT (character_id) DO UPDATE SET guild_id = $2, rank = $3"
		),
		[cid, gid, rank]
	)


static func _remove_member(cid: int) -> void:
	if _CM._test_skip_db:
		_test_members.erase(cid)
		return
	_CM.db_execute("DELETE FROM chars.guild_members WHERE character_id = $1", [cid])


static func _delete_guild(gid: int) -> void:
	if _CM._test_skip_db:
		for cid in _test_members.keys():
			if int(_test_members[cid]["guild_id"]) == gid:
				_test_members.erase(cid)
		_test_guilds.erase(gid)
		return
	# guild_members cascades on the guilds FK; delete the parent row and the name frees itself.
	_CM.db_execute("DELETE FROM chars.guilds WHERE id = $1", [gid])
