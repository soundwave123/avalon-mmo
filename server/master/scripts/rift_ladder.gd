extends RefCounted

# T-393: the Rift Trials keystone ladder on master — per-character keystone tier persisted in
# rift.keystone (migration 039), best-cleared-tier-per-season in rift.best_tier (the leaderboard
# read, the shared social-status seam with the T-390 PvP ladder), and a verdict ledger row per
# tier change (T-366 ledger discipline). Mirrors pvp_honor.gd's store shape: static funcs,
# _test_skip_db in-memory fakes, fail-closed writes.
#
# Server-authority (the whole point):
#   - "result" is SERVER-OBSERVED: the world calls it after IT adjudicates a timed clear/fail
#     (boss-death + its own clock). There is NO client verb that reaches it — the world's intent
#     allow-list never maps a client message to a result/set-tier action (adversarial-tested).
#   - The tier is read from rift.keystone HERE, never from a packet: even the world's call cannot
#     name a tier, only a holder — so a compromised param can at worst mis-verdict, never mint tier.
#   - The reward roll runs on the MASTER's rng with honest, monotonic odds; the bad-luck floor
#     (consecutive misses raise the next chance to a guarantee) is pure fairness, never for sale.

const _CM := preload("res://scripts/character_manager.gd")

# Each consecutive missed rift reward adds this to the NEXT roll's chance — a guaranteed hit
# within ceil(1/step) clears of pure bad luck. Resets on any hit. Published fairness, not pity.
const BAD_LUCK_STEP := 0.08
const LEADERBOARD_MAX := 25

static var _test_keystones: Dictionary = {}  # cid -> {tier, bad_luck}
static var _test_best: Dictionary = {}  # "cid|sid" -> tier
static var _test_ledger: Array = []
static var _test_randf: float = -1.0  # >= 0.0 forces the reward roll (deterministic tests)
static var _rng: RandomNumberGenerator = null


static func reset_for_test() -> void:
	_test_keystones.clear()
	_test_best.clear()
	_test_ledger.clear()
	_test_randf = -1.0


# ---- keystone state -----------------------------------------------------------


# The character's live keystone row; an absent row is the tier-1 baseline (fresh keys start at 1).
static func keystone(cid: int) -> Dictionary:
	if _CM._test_skip_db:
		var row: Dictionary = _test_keystones.get(cid, {})
		return {"tier": int(row.get("tier", 1)), "bad_luck": int(row.get("bad_luck", 0))}
	var rows: Variant = _CM.db_query(
		"SELECT tier, bad_luck FROM rift.keystone WHERE character_id = $1", [cid]
	)
	if rows is Array and (rows as Array).size() > 0:
		var r: Dictionary = rows[0]
		return {"tier": maxi(1, int(r.get("tier", 1))), "bad_luck": int(r.get("bad_luck", 0))}
	return {"tier": 1, "bad_luck": 0}


# The honest scaled reward chance: published base odds x the tier's reward weight, plus the
# bad-luck floor. Monotonic in tier (weight) AND in misses; hard-capped at certainty.
static func reward_chance(base: float, weight: float, misses: int) -> float:
	var scaled := clampf(base, 0.0, 1.0) * maxf(weight, 1.0)
	return clampf(scaled + float(maxi(misses, 0)) * BAD_LUCK_STEP, 0.0, 1.0)


# ---- op surface (master main routes "rift_op" here) ---------------------------


# Actions: "keystone" (read: own tier), "leaderboard" (read: season top-N best tiers), "result"
# (SERVER-OBSERVED: the world's adjudicated clear/fail — never reachable as a client intent).
# Anything else — including any forged "set_tier"/"grant" — is rejected.
static func op(params: Dictionary) -> Dictionary:
	var now := int(params.get("now", Time.get_unix_time_from_system()))
	var sid := int(params.get("season", 0))
	if sid <= 0:
		sid = int(PvpSeason.season_for(now)["id"])
	match str(params.get("action", "")):
		"keystone":
			var c := _CM.get_character(str(params.get("username", "")))
			if c.is_empty():
				return {"error": "unknown_character"}
			var ks := keystone(int(c["id"]))
			return {"ok": true, "tier": int(ks["tier"]), "season": sid}
		"leaderboard":
			var limit := clampi(int(params.get("limit", 10)), 1, LEADERBOARD_MAX)
			return {"ok": true, "season": sid, "entries": _leaderboard(sid, limit)}
		"result":
			return _record_result(params, sid)
	return {"error": "unknown_action"}


# ---- server-observed verdict ---------------------------------------------------


# One adjudicated run: upgrade the HOLDER's keystone on a clear / downgrade (floor 1) on a fail,
# credit every member's season best at the CLEARED tier, and roll each member's scaled reward.
# The tier is read from the holder's persisted keystone — the params can never name one.
static func _record_result(params: Dictionary, sid: int) -> Dictionary:
	var holder := _CM.get_character(str(params.get("holder", "")))
	if holder.is_empty():
		return {"error": "unknown_character"}
	var hid := int(holder["id"])
	var tier := int(keystone(hid)["tier"])
	var cleared := bool(params.get("cleared", false))
	var new_tier := tier + 1 if cleared else maxi(1, tier - 1)
	_write_tier(hid, new_tier)
	_ledger(hid, sid, tier, new_tier, "clear" if cleared else "fail")
	var rewards: Array = []
	if cleared:
		var reward: Dictionary = params.get("reward", {})
		var registry: Dictionary = params.get("item_registry", {})
		for uname in params.get("members", []):
			var c := _CM.get_character(str(uname))
			if c.is_empty():
				continue
			var cid := int(c["id"])
			_write_best(cid, sid, tier)
			rewards.append(_roll_reward(cid, str(uname), reward, registry))
	return {
		"ok": true,
		"cleared": cleared,
		"tier": tier,
		"new_tier": new_tier,
		"season": sid,
		"rewards": rewards,
	}


# One member's honest scaled loot roll. A hit grants the item and resets the bad-luck counter; a
# miss (or a full bag) advances it, so the floor keeps rising toward the guarantee.
static func _roll_reward(
	cid: int, uname: String, reward: Dictionary, registry: Dictionary
) -> Dictionary:
	var pool: Array = reward.get("pool", [])
	var misses := int(keystone(cid)["bad_luck"])
	var chance := reward_chance(
		float(reward.get("base_chance", 0.0)), float(reward.get("weight", 1.0)), misses
	)
	var item := ""
	if not pool.is_empty() and _roll() < chance:
		item = str(pool[_pick(pool.size())])
		var granted: Dictionary = _CM.try_add_items(cid, [{"item": item, "count": 1}], registry)
		if not bool(granted.get("ok", false)):
			item = ""  # bag full / unregistered — nothing granted, the floor keeps building
	_write_bad_luck(cid, 0 if item != "" else misses + 1)
	return {"username": uname, "item": item, "chance": chance, "misses": misses}


# ---- leaderboard read ----------------------------------------------------------


static func _leaderboard(sid: int, limit: int) -> Array:
	var rows: Array = []
	if _CM._test_skip_db:
		for key in _test_best:
			var parts: PackedStringArray = str(key).split("|")
			if int(parts[1]) != sid:
				continue
			var uname := str(_CM.get_character_by_id(int(parts[0])).get("username", ""))
			rows.append({"username": uname, "tier": int(_test_best[key])})
		rows.sort_custom(
			func(a, b):
				return (
					int(a["tier"]) > int(b["tier"])
					or (
						int(a["tier"]) == int(b["tier"]) and str(a["username"]) < str(b["username"])
					)
				)
		)
		rows = rows.slice(0, limit)
	else:
		var db: Variant = _CM.db_query(
			(
				"SELECT c.name AS username, b.tier FROM rift.best_tier b "
				+ "JOIN chars.characters c ON c.id = b.character_id "
				+ "WHERE b.season_id = $1 ORDER BY b.tier DESC, c.name ASC LIMIT $2"
			),
			[sid, limit]
		)
		if db is Array:
			for r: Dictionary in db:
				rows.append({"username": str(r.get("username", "")), "tier": int(r.get("tier", 1))})
	for i in rows.size():  # 1-based rank ride-along, the pvp_store leaderboard convention
		rows[i]["rank"] = i + 1
	return rows


# ---- writes --------------------------------------------------------------------


static func _write_tier(cid: int, tier: int) -> void:
	if _CM._test_skip_db:
		var row: Dictionary = _test_keystones.get(cid, {"tier": 1, "bad_luck": 0})
		row["tier"] = tier
		_test_keystones[cid] = row
		return
	_CM.db_execute(
		(
			"INSERT INTO rift.keystone (character_id, tier) VALUES ($1, $2) "
			+ "ON CONFLICT (character_id) DO UPDATE SET tier = $2"
		),
		[cid, tier]
	)


static func _write_bad_luck(cid: int, misses: int) -> void:
	if _CM._test_skip_db:
		var row: Dictionary = _test_keystones.get(cid, {"tier": 1, "bad_luck": 0})
		row["bad_luck"] = misses
		_test_keystones[cid] = row
		return
	_CM.db_execute(
		(
			"INSERT INTO rift.keystone (character_id, bad_luck) VALUES ($1, $2) "
			+ "ON CONFLICT (character_id) DO UPDATE SET bad_luck = $2"
		),
		[cid, misses]
	)


static func _write_best(cid: int, sid: int, tier: int) -> void:
	if _CM._test_skip_db:
		var key := "%d|%d" % [cid, sid]
		_test_best[key] = maxi(int(_test_best.get(key, 0)), tier)
		return
	_CM.db_execute(
		(
			"INSERT INTO rift.best_tier (character_id, season_id, tier) VALUES ($1, $2, $3) "
			+ "ON CONFLICT (character_id, season_id) "
			+ "DO UPDATE SET tier = GREATEST(rift.best_tier.tier, $3)"
		),
		[cid, sid, tier]
	)


static func _ledger(cid: int, sid: int, before: int, after: int, verdict: String) -> void:
	if _CM._test_skip_db:
		(
			_test_ledger
			. append(
				{
					"character_id": cid,
					"season_id": sid,
					"tier_before": before,
					"tier_after": after,
					"verdict": verdict,
				}
			)
		)
		return
	_CM.db_execute(
		(
			"INSERT INTO rift.ledger (character_id, season_id, tier_before, tier_after, verdict) "
			+ "VALUES ($1, $2, $3, $4, $5)"
		),
		[cid, sid, before, after, verdict]
	)


# ---- rng (master-owned; deterministic under test) ------------------------------


static func _roll() -> float:
	if _test_randf >= 0.0:
		return _test_randf
	return _rng_inst().randf()


static func _pick(size: int) -> int:
	if _test_randf >= 0.0:
		return 0
	return _rng_inst().randi_range(0, size - 1)


static func _rng_inst() -> RandomNumberGenerator:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	return _rng


# ---- test accessor -------------------------------------------------------------


static func test_ledger() -> Array:
	return _test_ledger
