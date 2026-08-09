class_name AchievementProgress
extends RefCounted

# T-367: pure achievement-progress evaluator — mirrors the pure-module idiom of leveling.gd /
# quest_state_machine.gd. "Complete" is DERIVED from tracked criteria counters, never stored as a
# separate truth: a def is earned the moment its counter clears its threshold, and once earned it
# stays earned (completion fires exactly once).
#
# HARD CONSTRAINTS: no DB, no OS time, deterministic, inputs are NEVER mutated (all returns are
# fresh copies). The master (character authority) owns persistence + reward grants; this module only
# decides what advanced and what newly completed.
#
# Counter model — one flat {counter_key: int} bag so any def reads a single key:
#   kill  -> "kill:<mob>" (+ "kill:*" running total). A specific-mob def reads "kill:goblin"; a
#            "defeat N enemies" def reads "kill:*".
#   reach/discovery -> "<event>:<target>" is a 0/1 flag (+ "<event>:*" running unique count).
#   quest -> "quest:<id>" is a 0/1 completion flag (+ "quest:*" = quests completed). Idempotent.
#   level -> "level" holds the character's max level reached (monotonic; a re-observed level is a
#            no-op because we keep the max).
#
# T-676: the counter model is data-generalized into three shapes so a NEW criteria event is just a
# name added to one list (no per-event `match` arm) — the same "adding an achievement is a new JSON
# row" spirit, extended to the vocabulary a row can reference:
#   COUNT -> running total "<event>:*" + per-subject "<event>:<key>" tally (kill/gather/craft/...).
#   FLAG  -> a 0/1 "<event>:<key>" flag + a unique running total "<event>:*" (reach/discovery/...).
#   MAX   -> a single monotonic "<event>" high-water mark (level/rating/mentor_credit).
# Two DERIVED counters are written by the completion loop itself (never by an external observe), so
# META-achievements watch other achievements without a new engine seam:
#   "achievement:*" -> every non-meta earn (the account "complete N achievements" ladder).
#   "group:<g>"     -> every earned member of group <g> (a per-zone / per-theme "complete the set").
# SUPPORTED_EVENTS is the whole vocabulary the T-676 catalog-integrity guard validates rows against.

const COUNT_EVENTS := ["kill", "discovery_zone", "pvp_win", "gather", "craft", "raid_clear"]
const FLAG_EVENTS := ["reach", "discovery", "quest", "recipe", "dungeon_boss"]
const MAX_EVENTS := ["level", "mentor_credit", "pvp_rating"]
const DERIVED_EVENTS := ["achievement", "group"]

# T-679: guild-SCOPED collective events — the SAME COUNT/FLAG/MAX machinery, aggregated at guild
# scope by GuildAchievementStore.observe (which credits the guild, never the individual member).
# Kept in the shared vocabulary so guild achievements ride the identical apply()/_resolve
# seam as character ones; no guild event is referenced by any per-character def.
#   guild_kill/gather/quest -> roster running totals (COUNT).
#   guild_member_cap (key=cid) -> distinct members at the level cap (FLAG: "guild_member_cap:*").
#   guild_dungeon_clear/guild_raid_clear (key=instance) -> first/Nth distinct clear (FLAG).
#   guild_online -> peak concurrent guildmates online (MAX high-water mark).
const GUILD_COUNT_EVENTS := ["guild_kill", "guild_gather", "guild_quest"]
const GUILD_FLAG_EVENTS := ["guild_member_cap", "guild_dungeon_clear", "guild_raid_clear"]
const GUILD_MAX_EVENTS := ["guild_online"]

const SUPPORTED_EVENTS := (
	COUNT_EVENTS
	+ FLAG_EVENTS
	+ MAX_EVENTS
	+ DERIVED_EVENTS
	+ GUILD_COUNT_EVENTS
	+ GUILD_FLAG_EVENTS
	+ GUILD_MAX_EVENTS
)


# Bump the counters for one observed event and re-derive completion. state is {counters, earned};
# returns a FRESH {counters, earned, newly_earned} (inputs untouched). key is the event subject
# (mob alias / reach target / quest id); "*" is a valid explicit total key. value carries the level.
static func apply(
	defs: Array, state: Dictionary, event: String, key: String, value: int = 0
) -> Dictionary:
	var counters: Dictionary = (state.get("counters", {}) as Dictionary).duplicate(true)
	var earned: Array = (state.get("earned", []) as Array).duplicate()
	if event in COUNT_EVENTS or event in GUILD_COUNT_EVENTS:
		_inc(counters, event + ":*")
		if key != "" and key != "*":
			_inc(counters, event + ":" + key)
	elif event in FLAG_EVENTS or event in GUILD_FLAG_EVENTS:
		# 0/1 flags — advancing the unique running total only on the FIRST sighting of this key.
		var ck := event + ":" + key
		if key != "" and key != "*" and int(counters.get(ck, 0)) == 0:
			counters[ck] = 1
			_inc(counters, event + ":*")
	elif event in MAX_EVENTS or event in GUILD_MAX_EVENTS:
		counters[event] = maxi(int(counters.get(event, 0)), value)
	var newly_earned := _resolve_completions(defs, counters, earned)
	return {"counters": counters, "earned": earned, "newly_earned": newly_earned}


# Fixed-point completion sweep: repeat until no def newly clears, so a meta-achievement whose LAST
# member completes on THIS observe earns in the same call (metas can chain onto metas, still bounded
# by the def count). Each def earns exactly once (the earned guard) so nothing double-credits, and
# every non-meta earn feeds the derived meta counters that higher tiers watch.
static func _resolve_completions(defs: Array, counters: Dictionary, earned: Array) -> Array:
	var newly_earned: Array = []
	var changed := true
	while changed:
		changed = false
		for def: Dictionary in defs:
			var aid := str(def.get("id", ""))
			if aid == "" or earned.has(aid):
				continue
			if _is_complete(def.get("criteria", {}), counters):
				earned.append(aid)
				newly_earned.append(aid)
				_credit_meta_counters(counters, def)
				changed = true
	return newly_earned


# On a fresh earn, feed the engine-derived meta counters. Metas are excluded from "achievement:*" so
# the "complete N achievements" ladder counts real content, not the milestones sitting on top of it.
static func _credit_meta_counters(counters: Dictionary, def: Dictionary) -> void:
	if bool(def.get("meta", false)):
		return
	_inc(counters, "achievement:*")
	for g: Variant in def.get("groups", []):
		_inc(counters, "group:" + str(g))


# True when the def's tracked counter has cleared its threshold.
static func _is_complete(criteria: Dictionary, counters: Dictionary) -> bool:
	if criteria.is_empty():
		return false
	var need := int(criteria.get("count", 1))
	var have := int(counters.get(_criteria_key(criteria), 0))
	return have >= need


# The single counter a def watches — MAX events are one global high-water mark, the rest key on
# "<event>:<key>" (the derived "achievement"/"group" metas fall through here, e.g. "group:z").
static func _criteria_key(criteria: Dictionary) -> String:
	var event := str(criteria.get("event", ""))
	if event in MAX_EVENTS or event in GUILD_MAX_EVENTS:
		return event
	return event + ":" + str(criteria.get("key", "*"))


# A def's completion fraction [0.0, 1.0] for the client progress bar (pure read of counters).
static func fraction(criteria: Dictionary, counters: Dictionary) -> float:
	var need := maxi(1, int(criteria.get("count", 1)))
	var have := int(counters.get(_criteria_key(criteria), 0))
	return clampf(float(have) / float(need), 0.0, 1.0)


static func _inc(counters: Dictionary, ckey: String) -> void:
	counters[ckey] = int(counters.get(ckey, 0)) + 1
