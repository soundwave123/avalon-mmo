class_name MmrMatchmaker
extends RefCounted

# T-392: the PURE MMR matchmaking brain (mirrors EloRating / npc_wander purity — no I/O, no state,
# no OS clock; the caller injects the queue + the published band params). A queue calls in here to
# turn an arrival-ordered lobby into FAIR pairings; the store owns the ratings, the queue owns the
# wait clock, this owns only the math. Unit-tested headlessly.
#
# Server-authority: a client never reaches this. The world resolves each queuer's identity from its
# live session and reads their MMR from the master (PvpStore.mmr_for) — a client supplies neither an
# MMR nor an opponent id. The band params are PUBLISHED data (data/pvp_matchmaking.json); there is
# no hidden tolerance the player can't read.

const _CFG_PATH := "res://data/pvp_matchmaking.json"

static var _cfg: Dictionary = {}


static func config() -> Dictionary:
	if _cfg.is_empty():
		var f := FileAccess.open(_CFG_PATH, FileAccess.READ)
		if f != null:
			var doc: Variant = JSON.parse_string(f.get_as_text())
			if typeof(doc) == TYPE_DICTIONARY:
				_cfg = doc
	return _cfg


static func reset_cache_for_test() -> void:
	_cfg = {}


# The MMR tolerance for a queuer who has waited `wait_secs`: starts at the tight base_band and
# widens by widen_per_sec each second, HARD-clamped to [base_band, max_band] (a floor so a fresh
# queuer only faces a near-peer; a ceiling so nobody ever waits into an unwinnable blowout).
static func band_for(wait_secs: int, band: Dictionary) -> int:
	var base := int(band.get("base_band", 100))
	var per := int(band.get("widen_per_sec", 8))
	var maxb := int(band.get("max_band", 600))
	return clampi(base + per * maxi(wait_secs, 0), base, maxb)


# TRUE if two queuers may be paired: their MMR gap fits inside the band of whichever has waited
# LONGER (the more patient player's widened tolerance carries the pair).
static func can_match(mmr_a: int, mmr_b: int, wait_a: int, wait_b: int, band: Dictionary) -> bool:
	return absi(mmr_a - mmr_b) <= band_for(maxi(wait_a, wait_b), band)


# entries: [{id, mmr, wait}] (wait optional, default 0). Returns {pairs: [[id, id], ...],
# unmatched: [id, ...]}. Greedy nearest-MMR: sort by rating, pair each queuer with the next-closest
# one when they fall inside the widening band, else leave them to keep waiting. Deterministic.
static func pair_queue(entries: Array, band: Dictionary) -> Dictionary:
	var sorted := entries.duplicate()
	sorted.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return int(a["mmr"]) < int(b["mmr"])
	)
	var pairs: Array = []
	var unmatched: Array = []
	var i := 0
	while i < sorted.size():
		var a: Dictionary = sorted[i]
		if (
			i + 1 < sorted.size()
			and can_match(
				int(a["mmr"]),
				int(sorted[i + 1]["mmr"]),
				int(a.get("wait", 0)),
				int(sorted[i + 1].get("wait", 0)),
				band,
			)
		):
			pairs.append([a["id"], sorted[i + 1]["id"]])
			i += 2
		else:
			unmatched.append(a["id"])
			i += 1
	return {"pairs": pairs, "unmatched": unmatched}


# Split N pre-selected members into two MMR-balanced teams of `team_size` (the T-413 BG team seam:
# once the queue has PLAYERS_NEEDED, assign teams to minimize the rating gap instead of splitting by
# arrival order). members: [{id, mmr}]. Greedy: seed the strongest, then feed each next-strongest to
# the lighter team with open slots. Returns {teams: [[id...], [id...]], mmr_gap}.
static func balance_teams(members: Array, team_size: int) -> Dictionary:
	var s := members.duplicate()
	s.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["mmr"]) > int(b["mmr"]))
	var teams: Array = [[], []]
	var sums := [0, 0]
	for m: Dictionary in s:
		var t := 0
		var t0_full: bool = (teams[0] as Array).size() >= team_size
		var t1_full: bool = (teams[1] as Array).size() >= team_size
		if t0_full:
			t = 1
		elif t1_full:
			t = 0
		elif int(sums[0]) > int(sums[1]):
			t = 1
		(teams[t] as Array).append(m["id"])
		sums[t] = int(sums[t]) + int(m["mmr"])
	return {"teams": teams, "mmr_gap": absi(int(sums[0]) - int(sums[1]))}
