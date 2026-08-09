extends GutTest

# T-390: the PURE season-window brain — id/start/end derived from an injected server clock only.

const PvpSeason = preload("res://scripts/pvp_season.gd")


func test_epoch_is_season_one() -> void:
	var s := PvpSeason.season_for(PvpSeason.EPOCH_UNIX)
	assert_eq(int(s["id"]), 1)
	assert_eq(int(s["starts_at"]), PvpSeason.EPOCH_UNIX)
	assert_eq(int(s["ends_at"]), PvpSeason.EPOCH_UNIX + PvpSeason.SEASON_SECS)


func test_rollover_advances_the_id_and_window() -> void:
	# One second into the SECOND window is season 2, with a contiguous start = prior end.
	var s1 := PvpSeason.season_for(PvpSeason.EPOCH_UNIX + PvpSeason.SEASON_SECS - 1)
	var s2 := PvpSeason.season_for(PvpSeason.EPOCH_UNIX + PvpSeason.SEASON_SECS + 1)
	assert_eq(int(s1["id"]), 1)
	assert_eq(int(s2["id"]), 2)
	assert_eq(int(s2["starts_at"]), int(s1["ends_at"]), "windows are contiguous")


func test_before_epoch_clamps_to_season_one() -> void:
	# A fail-safe: a clock before the epoch never yields a zero/negative season id.
	assert_eq(int(PvpSeason.season_for(0)["id"]), 1)
	assert_eq(int(PvpSeason.season_for(PvpSeason.EPOCH_UNIX - 999)["id"]), 1)


func test_config_override_seam() -> void:
	# The store-injected override path: a 10s season, 25s in => season 3.
	var s := PvpSeason.season_for_config(1025, 1000, 10)
	assert_eq(int(s["id"]), 3)
	assert_eq(int(s["starts_at"]), 1020)
	assert_eq(int(s["ends_at"]), 1030)
