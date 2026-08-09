class_name PvpSeason
extends RefCounted

# T-390: the PURE season-window brain. A season is a fixed wall-clock window; its id and boundaries
# are DERIVED from the SERVER clock ALONE — no client input names a season, sets its start, or picks
# a placement window (server-authority checklist). The store injects `now` (the master's own
# Time.get_unix_time_from_system()), so this is deterministic + unit-testable with a fixed clock.
#
# The window constants live here as the single source of truth. A future server-config override is a
# clean seam (season_for_config takes epoch/length) but is deferred (see the ticket Deferred note).

const EPOCH_UNIX := 1_735_689_600  # 2025-01-01T00:00:00Z — season 1 begins at the epoch
const SEASON_DAYS := 90  # a quarter-length ladder (WoW / FFXIV seasonal cadence)
const SEASON_SECS := SEASON_DAYS * 86400


# The season covering `now`: {id (1-based), starts_at, ends_at} (unix seconds). A `now` before the
# epoch clamps to season 1 (fail-safe — never a zero/negative id).
static func season_for(now: int) -> Dictionary:
	return season_for_config(now, EPOCH_UNIX, SEASON_SECS)


static func season_for_config(now: int, epoch: int, secs: int) -> Dictionary:
	var elapsed := now - epoch
	var idx := 0 if elapsed < 0 else int(elapsed / secs)
	return {
		"id": idx + 1,
		"starts_at": epoch + idx * secs,
		"ends_at": epoch + (idx + 1) * secs,
	}
