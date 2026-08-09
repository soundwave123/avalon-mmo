extends RefCounted

# T-394: the seasonal wrap over the T-393 Rift Trials engine, on the SHARED T-390 clock
# (PvpSeason is the single season brain — never forked; owner cadence = SEASON_DAYS/EPOCH_UNIX
# through the season_for_config seam). The ladder is fresh per season structurally
# (rift.best_tier is season-keyed); the reward track is published, cosmetic-only data.
#
# SOFT reset: on first sighting of a new season each prior participant is settled EXACTLY once
# (the rift.season_snapshot INSERT ... ON CONFLICT DO NOTHING RETURNING claim — the
# pvp.season_grants idempotency pattern): standings snapshot (THE T-395 HOOK), keystone
# regressed TOWARD the floor (carry_fraction of progress kept — never a wipe), cosmetic tiers
# granted. ETERNAL HOME: rollover touches ONLY rift.* rows + cosmetic grants — no DELETE
# anywhere on the path; characters/gear/coin/cosmetics are untouchable (asserted in test).
#
# Server-authority: season id/window derive from the master clock alone; no client input can
# name a season, trigger a rollover, or set a season score — forged actions are rejected
# (adversarial-tested).

const _CM := preload("res://scripts/character_manager.gd")
const RiftLadder := preload("res://scripts/rift_ladder.gd")
const PvpSeason := preload("res://scripts/pvp_season.gd")
const WardrobeOps := preload("res://scripts/wardrobe_ops.gd")

const _CFG_PATH := "res://data/rift_season.json"
const DEFAULT_FLOOR_TIER := 1
const DEFAULT_CARRY_FRACTION := 0.5
# T-482 audit trail: a season grant is auditably distinct from "store" and plain "grant".
const UNLOCK_SOURCE := "season"

static var _cfg: Dictionary = {}
static var _test_snapshots: Dictionary = {}  # "cid|sid" -> snapshot row


static func reset_for_test() -> void:
	_test_snapshots.clear()


# ---- published config (owner-tunable floor + reward track) ---------------------


static func config() -> Dictionary:
	if _cfg.is_empty():
		var f := FileAccess.open(_CFG_PATH, FileAccess.READ)
		if f != null:
			var doc: Variant = JSON.parse_string(f.get_as_text())
			if typeof(doc) == TYPE_DICTIONARY:
				_cfg = doc
	return _cfg


# The floor the soft reset regresses TOWARD. Never below tier 1 (the keystone baseline).
static func floor_tier() -> int:
	return maxi(int(config().get("season", {}).get("floor_tier", DEFAULT_FLOOR_TIER)), 1)


# The fraction of progress ABOVE the floor a veteran keeps across a rollover (D2: a partial
# floor — regress toward, not to, the floor). Clamped so config can never inflate a keystone.
static func carry_fraction() -> float:
	return clampf(
		float(config().get("season", {}).get("carry_fraction", DEFAULT_CARRY_FRACTION)), 0.0, 1.0
	)


# Pure soft-reset math: floor + carry of the progress above it. Monotonic, never below the
# floor, never above the input tier — a REGRESSION, not a wipe and not a reward.
static func regressed_tier(tier: int) -> int:
	var fl := floor_tier()
	if tier <= fl:
		return fl
	return fl + int(floorf(float(tier - fl) * carry_fraction()))


# ---- season read (the return-trigger data hook) --------------------------------


# The current window + the NEXT season's start — the honest "a new season is coming/here"
# data seam (invitation only; there is nothing to lose, so no message can threaten loss).
static func season_read(now: int) -> Dictionary:
	var s := PvpSeason.season_for(now)
	return {
		"ok": true,
		"season": int(s["id"]),
		"starts_at": int(s["starts_at"]),
		"ends_at": int(s["ends_at"]),
		"season_days": PvpSeason.SEASON_DAYS,
		"next_season": int(s["id"]) + 1,
		"next_starts_at": int(s["ends_at"]),
	}


# ---- dispatch (master main routes "rift_op" here) ------------------------------


# Every rift op sighting runs the rollover observer first (the pvp_store.ensure_season idiom:
# redundant re-entry is a per-character no-op), then routes: "season" is the window read (any
# forged season/score field in params is simply never read — the id derives from `now` alone);
# every other action falls through to RiftLadder.op, whose allow-list rejects forgeries.
static func dispatch(params: Dictionary) -> Dictionary:
	var now := int(params.get("now", Time.get_unix_time_from_system()))
	ensure_rollover(now)
	if str(params.get("action", "")) == "season":
		return season_read(now)
	return RiftLadder.op(params)


# ---- rollover observer (server clock only) -------------------------------------


# Settle the season BEFORE the one covering `now`. Returns how many characters were settled
# this call (0 on re-entry — idempotent per character via the snapshot claim).
static func ensure_rollover(now: int) -> int:
	var sid := int(PvpSeason.season_for(now)["id"])
	if sid <= 1:
		return 0
	return _settle(sid - 1)


# One prior-season settle pass. Per participant: claim the snapshot (exactly-once spine),
# regress the keystone toward the floor, ledger the reset, grant the season's cosmetic tiers.
static func _settle(prev_sid: int) -> int:
	var settled := 0
	for row: Dictionary in _standings(prev_sid):
		var cid := int(row["character_id"])
		var best := int(row["tier"])
		var before := int(RiftLadder.keystone(cid)["tier"])
		var after := regressed_tier(before)
		if not _claim_snapshot(cid, prev_sid, best, before, after):
			continue  # already settled — idempotent
		# Bounded regression write + audit row via the ladder's own storage tail (shared
		# in-memory fakes under test; the ONLY mutation the rollover makes outside rift
		# snapshot/ledger rows — the eternal-home contract).
		RiftLadder._write_tier(cid, after)
		RiftLadder._ledger(cid, prev_sid, before, after, "season_reset")
		_grant_rewards(cid, best)
		settled += 1
	return settled


# The prior season's standings: every (character, best cleared tier) with a score that season.
static func _standings(sid: int) -> Array:
	var out: Array = []
	if _CM._test_skip_db:
		for key in RiftLadder._test_best:
			var parts: PackedStringArray = str(key).split("|")
			if int(parts[1]) == sid:
				out.append({"character_id": int(parts[0]), "tier": int(RiftLadder._test_best[key])})
		return out
	var rows: Variant = _CM.db_query(
		"SELECT character_id, tier FROM rift.best_tier WHERE season_id = $1", [sid]
	)
	if rows is Array:
		for r: Dictionary in rows:
			out.append({"character_id": int(r["character_id"]), "tier": int(r["tier"])})
	return out


# Exactly-once claim per (character, season): RETURNING makes the conflict observable — an
# already-written snapshot returns zero rows, so re-entry settles nothing (the pvp._claim_grant
# lesson: db_execute's boolean would read success either way and break idempotency).
static func _claim_snapshot(cid: int, sid: int, best: int, before: int, after: int) -> bool:
	if _CM._test_skip_db:
		var key := "%d|%d" % [cid, sid]
		if _test_snapshots.has(key):
			return false
		_test_snapshots[key] = {
			"character_id": cid,
			"season_id": sid,
			"best_tier": best,
			"keystone_before": before,
			"keystone_after": after,
		}
		return true
	var rows: Variant = _CM.db_query(
		(
			"INSERT INTO rift.season_snapshot "
			+ "(character_id, season_id, best_tier, keystone_before, keystone_after) "
			+ "VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING RETURNING character_id"
		),
		[cid, sid, best, before, after]
	)
	return rows is Array and (rows as Array).size() > 0


# The seasonal reward track: every published tier the season's best cleared tier reached, PLUS the
# evergreen milestone titles past the last authored tier (T-538). 100% cosmetic (titles/skins — D3,
# T-482 charter: no power, nothing bought outranks earned); lands on the T-375/T-428 seam with the
# auditable "season" source. Re-grant is a no-op.
static func _grant_rewards(cid: int, best: int) -> void:
	for t: Dictionary in config().get("reward_tiers", []):
		if best >= int(t.get("min_best_tier", 0)):
			WardrobeOps.grant_unlock(cid, str(t.get("unlock", "")), UNLOCK_SOURCE)
	for u: String in milestone_unlocks(best):
		WardrobeOps.grant_unlock(cid, u, UNLOCK_SOURCE)


# T-538: the EVERGREEN milestone cadence — pure, so the "there is ALWAYS a next prize" guarantee is
# unit-testable without the DB. Every `cadence` best-tiers from `first_best_tier` up, one more
# numbered ascendant title (rift_ascendant_1, _2, ...). Unbounded in feel (a `max` guard only stops
# a pathological best from an infinite loop — the tier is server truth, never a packet). Data-driven
# cadence/first/prefix, cosmetic-only, so it can never confer power or drift off the charter.
static func milestone_unlocks(best: int) -> Array:
	var m: Dictionary = config().get("milestones", {})
	var first := int(m.get("first_best_tier", 0))
	var cadence := maxi(int(m.get("cadence", 0)), 1)
	var prefix := str(m.get("unlock_prefix", ""))
	var cap := maxi(int(m.get("max", 0)), 0)
	var out: Array = []
	if first <= 0 or prefix == "":
		return out
	var idx := 1
	var threshold := first
	while best >= threshold and (cap <= 0 or idx <= cap):
		out.append("%s_%d" % [prefix, idx])
		idx += 1
		threshold += cadence
	return out


# ---- T-395 consumption hook ------------------------------------------------------


# THE HOOK: a season's permanent standings snapshot, best tier first. T-395's prestige track
# reads these rows (they are never deleted); each row carries the soft-reset audit pair too.
static func snapshots_for_season(sid: int) -> Array:
	var out: Array = []
	if _CM._test_skip_db:
		for key in _test_snapshots:
			var row: Dictionary = _test_snapshots[key]
			if int(row["season_id"]) == sid:
				out.append(row.duplicate())
	else:
		var rows: Variant = _CM.db_query(
			(
				"SELECT character_id, season_id, best_tier, keystone_before, keystone_after "
				+ "FROM rift.season_snapshot WHERE season_id = $1 ORDER BY best_tier DESC"
			),
			[sid]
		)
		if rows is Array:
			for r: Dictionary in rows:
				out.append(r)
	out.sort_custom(func(a, b): return int(a["best_tier"]) > int(b["best_tier"]))
	return out
