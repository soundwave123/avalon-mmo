extends RefCounted

# T-395: horizontal prestige / account-mastery — the PERMANENT floor beneath the T-394 seasonal
# ladder. A single always-climbing number: server-observed play (the T-394 rift season snapshot,
# T-410 commendations, PvP, world content) feeds mastery XP through a published weight table; the
# level curve is pure, monotonic, and unbounded (the Paragon *feel*); every level's reward is
# HORIZONTAL ONLY — a title or cosmetic on the T-375/T-428 seam (source "mastery", T-482 charter).
# A reward row that is anything but {level, unlock:title|skin} is refused at grant time, so a
# power stat CANNOT ride this track even by config mistake (asserted in test).
#
# NEVER RESETS: mastery.progress is keyed by subject (account username by default; "char:<id>"
# under the owner-tunable character scope) and is not season-keyed — the T-394 rollover's
# write-set structurally cannot touch it (asserted in test).
#
# Server-authority: there is NO client verb that grants mastery XP, a level, or a reward.
# observe() is called by server systems only; the op surface is the "read" action alone, and the
# rift-season feed is claimed exactly once per (subject, season) via mastery.feed_claim
# (the pvp.season_grants idempotency spine). Forged set/observe/grant actions are rejected.

const _CM := preload("res://scripts/character_manager.gd")
const RiftSeason := preload("res://scripts/rift_season.gd")
const PvpSeason := preload("res://scripts/pvp_season.gd")
const WardrobeOps := preload("res://scripts/wardrobe_ops.gd")

const _CFG_PATH := "res://data/account_mastery.json"
# T-482 audit trail: a mastery grant is auditably distinct from "store"/"grant"/"season".
const UNLOCK_SOURCE := "mastery"
const DEFAULT_BASE_COST := 100
const DEFAULT_STEP_COST := 25
# The horizontal-only contract: a reward row is EXACTLY {level, unlock} and the unlock id must
# live in one of these cosmetic namespaces. Anything else is refused (never granted).
const _REWARD_KEYS := ["level", "unlock"]
const _UNLOCK_PREFIXES := ["title:", "skin_"]

static var _cfg: Dictionary = {}
static var _test_progress: Dictionary = {}  # subject -> {xp, level}
static var _test_ledger: Array = []
static var _test_claims: Dictionary = {}  # "subject|feed" -> true


static func reset_for_test() -> void:
	_cfg = {}
	_test_progress.clear()
	_test_ledger.clear()
	_test_claims.clear()


# ---- published config (owner-tunable scope + weights + reward table) ------------


static func config() -> Dictionary:
	if _cfg.is_empty():
		var f := FileAccess.open(_CFG_PATH, FileAccess.READ)
		if f != null:
			var doc: Variant = JSON.parse_string(f.get_as_text())
			if typeof(doc) == TYPE_DICTIONARY:
				_cfg = doc
	return _cfg


# D1 (owner-tunable): "account" (default — the alt-friendly renown shape) or "character".
static func scope() -> String:
	return "character" if str(config().get("scope", "account")) == "character" else "account"


static func base_cost() -> int:
	return maxi(int(config().get("curve", {}).get("base_cost", DEFAULT_BASE_COST)), 1)


static func step_cost() -> int:
	return maxi(int(config().get("curve", {}).get("step_cost", DEFAULT_STEP_COST)), 0)


# The published weight of one server-observed unit of a source; 0 = unknown (fail-closed).
static func source_weight(source: String) -> int:
	return maxi(int(config().get("sources", {}).get(source, 0)), 0)


# ---- pure level curve (monotonic, unbounded) ------------------------------------


# XP to advance FROM `level` to `level + 1`: a linear ramp, so the cumulative curve is quadratic
# — each level costs more (earned but reachable, D3), yet the number NEVER hard-walls (D4).
static func cost_for_next(level: int) -> int:
	return base_cost() + step_cost() * maxi(level, 0)


# Total XP at which `level` is reached (level 0 is the start). Closed form of the ramp sum.
static func xp_to_reach(level: int) -> int:
	var l := maxi(level, 0)
	return base_cost() * l + step_cost() * l * (l - 1) / 2


# The level a lifetime XP total has earned — closed-form floor of the inverted ramp, then a
# guard step (no loops, so an absurd XP value cannot stall the master).
static func level_for_xp(xp: int) -> int:
	var x := maxi(xp, 0)
	var level := 0
	if step_cost() == 0:
		level = x / base_cost()
	else:
		var b := float(base_cost()) - float(step_cost()) / 2.0
		var disc := b * b + 2.0 * float(step_cost()) * float(x)
		level = maxi(int((sqrt(disc) - b) / float(step_cost())), 0)
	while level > 0 and xp_to_reach(level) > x:
		level -= 1
	while xp_to_reach(level + 1) <= x:
		level += 1
	return level


# ---- subject resolution (the account-vs-character owner dial) -------------------


# The progress-row key. Account scope keys on the login username (characters share it after
# T-507); character scope keys on the character id. Never taken from a packet — callers pass
# identity the server already resolved.
static func subject_for(username: String, character_id: int) -> String:
	if scope() == "character":
		return "char:%d" % character_id
	return username


# ---- progress state -------------------------------------------------------------


static func progress(subject: String) -> Dictionary:
	if _CM._test_skip_db:
		var row: Dictionary = _test_progress.get(subject, {})
		return {"xp": int(row.get("xp", 0)), "level": int(row.get("level", 0))}
	var rows: Variant = _CM.db_query(
		"SELECT xp, level FROM mastery.progress WHERE subject = $1", [subject]
	)
	if rows is Array and (rows as Array).size() > 0:
		var r: Dictionary = rows[0]
		return {"xp": int(r.get("xp", 0)), "level": int(r.get("level", 0))}
	return {"xp": 0, "level": 0}


# ---- server-observed accrual (the ONLY way mastery moves — always up) -----------


# Credit `units` of a published source to a server-resolved identity. Fail-closed: an unknown
# source or non-positive unit count writes nothing. XP only ever increases (monotonic — the
# schema CHECKs agree); a level-up grants every authored horizontal reward at or below the new
# level (re-grants are no-ops on the unlock seam, so missed grants self-heal).
static func observe(username: String, character_id: int, source: String, units: int) -> Dictionary:
	var weight := source_weight(source)
	if weight <= 0 or units <= 0 or character_id <= 0:
		return {"error": "unknown_source"}
	var subject := subject_for(username, character_id)
	var before := progress(subject)
	var xp := int(before["xp"]) + weight * units
	var level := level_for_xp(xp)
	_write_progress(subject, xp, level)
	_ledger(subject, source, weight * units)
	var granted: Array = []
	if level > int(before["level"]):
		granted = _grant_rewards(username, character_id, level)
	return {"ok": true, "xp": xp, "level": level, "granted": granted}


# T-548: mastery is earned by the ACCOUNT, so its horizontal rewards are OWNED AT THE ACCOUNT
# level in account scope — every current AND future alt of the account can wear a title/skin the
# account earned (the unlock is keyed on the account username, read back by WardrobeOps.unlocks_for
# for any of that account's characters). In the owner's character scope the track is per-character,
# so the grant stays per-character. Either way a reward at or below `level` is refused unless it is
# horizontal-only shaped, and both unlock seams are idempotent (ON CONFLICT DO NOTHING) so a
# re-walk can never double-grant.
static func _grant_rewards(username: String, character_id: int, level: int) -> Array:
	var granted: Array = []
	var account_wide := scope() != "character"
	for t: Dictionary in config().get("reward_levels", []):
		if not _is_horizontal_reward(t):
			continue  # the charter guard: a malformed/power row is never granted
		if level >= int(t["level"]):
			var unlock := str(t["unlock"])
			if account_wide:
				WardrobeOps.grant_account_unlock(username, unlock, UNLOCK_SOURCE)
			else:
				WardrobeOps.grant_unlock(character_id, unlock, UNLOCK_SOURCE)
			granted.append(unlock)
	return granted


# The hard T-482 rule, enforced at grant time: EXACTLY {level, unlock}, unlock in a cosmetic
# namespace. A "stat"/"power"/anything-else row cannot pay out no matter what config says.
static func _is_horizontal_reward(t: Dictionary) -> bool:
	var keys := t.keys()
	keys.sort()
	if keys != _REWARD_KEYS:
		return false
	var unlock := str(t["unlock"])
	for prefix: String in _UNLOCK_PREFIXES:
		if unlock.begins_with(prefix):
			return true
	return false


# ---- the T-394 season-snapshot feed (exactly once per subject per season) -------


# Consume a settled season's rift.season_snapshot rows (RiftSeason.snapshots_for_season — the
# hook T-394 built for this ticket): each participant's best cleared tier becomes mastery XP at
# the published weight, claimed exactly once per (subject, season) via mastery.feed_claim.
#
# T-547: snapshots are PER CHARACTER but the feed is claimed once per (subject, season). In
# account scope an account's alts all share one subject, so we must aggregate the per-character
# snapshots to the subject FIRST and credit the account from its single MAX best_tier across all
# its characters — never the arbitrary first-iterated row (which silently dropped every other
# alt's season, and wasn't even the account's best). In character scope each alt is its own
# subject, so the same group-by-subject-then-max is a no-op that credits each character its own
# best. The claim stays exactly-once per (subject, season): a re-drain credits nothing.
static func consume_season(sid: int) -> int:
	if sid < 1:
		return 0
	# subject -> {best, username, cid} : the account's (or character's) MAX season result.
	var best_by_subject: Dictionary = {}
	for row: Dictionary in RiftSeason.snapshots_for_season(sid):
		var cid := int(row["character_id"])
		var best := int(row["best_tier"])
		var username := str(_CM.get_character_by_id(cid).get("username", ""))
		if username == "" or best <= 0:
			continue
		var subject := subject_for(username, cid)
		var cur: Dictionary = best_by_subject.get(subject, {"best": 0})
		if best > int(cur["best"]):
			best_by_subject[subject] = {"best": best, "username": username, "cid": cid}
	var credited := 0
	for subject: String in best_by_subject:
		if not _claim_feed(subject, "rift_season:%d" % sid):
			continue  # already credited — idempotent
		var win: Dictionary = best_by_subject[subject]
		observe(str(win["username"]), int(win["cid"]), "season_best_tier", int(win["best"]))
		credited += 1
	return credited


# Exactly-once claim (the pvp._claim_grant lesson: RETURNING makes the conflict observable).
static func _claim_feed(subject: String, feed: String) -> bool:
	if _CM._test_skip_db:
		var key := "%s|%s" % [subject, feed]
		if _test_claims.has(key):
			return false
		_test_claims[key] = true
		return true
	var rows: Variant = _CM.db_query(
		(
			"INSERT INTO mastery.feed_claim (subject, feed) VALUES ($1, $2) "
			+ "ON CONFLICT DO NOTHING RETURNING subject"
		),
		[subject, feed]
	)
	return rows is Array and (rows as Array).size() > 0


# ---- op surface (master main routes "mastery_op" here) --------------------------


# The ONLY routed action is "read" (own mastery, session-resolved identity). Every sighting
# first runs the T-394 rollover observer then drains the prior season's snapshot feed, so the
# permanent floor absorbs a finished season without any dedicated tick. Forged
# set_xp/set_level/observe/grant actions all fall through to rejection — no client input can
# move mastery in any direction.
static func dispatch(params: Dictionary) -> Dictionary:
	var now := int(params.get("now", Time.get_unix_time_from_system()))
	RiftSeason.ensure_rollover(now)
	var sid := int(PvpSeason.season_for(now)["id"])
	if sid > 1:
		consume_season(sid - 1)
	if str(params.get("action", "")) == "read":
		var c := _CM.get_character(str(params.get("username", "")))
		if c.is_empty():
			return {"error": "unknown_character"}
		var p := progress(subject_for(str(c["username"]), int(c["id"])))
		return {
			"ok": true,
			"xp": int(p["xp"]),
			"level": int(p["level"]),
			"next_level_xp": xp_to_reach(int(p["level"]) + 1),
			"scope": scope(),
			"season": sid,
		}
	return {"error": "unknown_action"}


# ---- writes ---------------------------------------------------------------------


static func _write_progress(subject: String, xp: int, level: int) -> void:
	if _CM._test_skip_db:
		_test_progress[subject] = {"xp": xp, "level": level}
		return
	_CM.db_execute(
		(
			"INSERT INTO mastery.progress (subject, xp, level) VALUES ($1, $2, $3) "
			+ "ON CONFLICT (subject) DO UPDATE SET xp = $2, level = $3"
		),
		[subject, xp, level]
	)


static func _ledger(subject: String, source: String, amount: int) -> void:
	if _CM._test_skip_db:
		_test_ledger.append({"subject": subject, "source": source, "amount": amount})
		return
	_CM.db_execute(
		"INSERT INTO mastery.ledger (subject, source, amount) VALUES ($1, $2, $3)",
		[subject, source, amount]
	)


# ---- test accessor --------------------------------------------------------------


static func test_ledger() -> Array:
	return _test_ledger
