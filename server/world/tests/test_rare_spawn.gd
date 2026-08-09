# T-411: RARE / variable-ratio spawn tuning — headless unit tests.
#
# Covers the fun-audit-2 burst-injection mechanism that rides the existing spawn/respawn machinery:
#   1. spawn_chance / respawn_ticks are FAIL-OPEN on the spawns.json entry — an ordinary entry that
#      omits them is byte-for-byte unchanged (always present, global ServerConfig dwell).
#   2. the authored Ashmoor rare entry loads its low chance + long dwell onto the MobData.
#   3. mob_loader.next_respawn_ticks folds the variable-ratio roll into the single respawn_at the
#      world computes at kill time: an ordinary mob returns its base dwell exactly; a rare draws a
#      GEOMETRIC number of dormant cycles (bounded), so its return is unpredictable but never
#      strands forever and never returns EARLY.
# Pure loader + deterministic seeded rng — no OS time, no engine loop, no network.

extends GutTest

const _MD = preload("res://scripts/combat/mob_data.gd")
const _ML = preload("res://scripts/combat/mob_loader.gd")
const _SC = preload("res://scripts/server_config.gd")

const _MOBS_DIR := "res://data/mobs"


func _make_rng(seed_val: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	return rng


func _mob(chance: float, ticks: int):
	var m = _MD.new()
	m.spawn_chance = chance
	m.respawn_ticks = ticks
	return m


# ---- fail-open loading: ordinary entries are untouched -------------------------------------


func test_ordinary_spawn_entries_default_fail_open() -> void:
	var mobs := _ML.load_spawn_table(_MOBS_DIR)
	assert_gt(mobs.size(), 0, "spawn table loads")
	# Every mob that is NOT the authored rare inherits the always-present defaults. T-708 authors a
	# FASTER starter-band dwell (wolves, 300 ticks), so the invariant is directional now: an
	# ordinary mob may respawn quicker than the global dwell but never author a rare-style LONG
	# dwell or partial presence without being the declared rare.
	for id in mobs:
		if mobs[id].mob_id == "mob_rare_ashmoor_kingpin":
			continue
		assert_eq(
			mobs[id].spawn_chance,
			1.0,
			"%s keeps spawn_chance 1.0 (always present)" % mobs[id].mob_id
		)
		assert_lte(
			mobs[id].respawn_ticks,
			_SC.MOB_RESPAWN_TICKS,
			(
				"%s stays at/below the global respawn dwell (only the rare dwells long)"
				% mobs[id].mob_id
			)
		)


func test_authored_rare_loads_low_chance_and_long_dwell() -> void:
	var mobs := _ML.load_spawn_table(_MOBS_DIR)
	var rare = null
	for id in mobs:
		if mobs[id].mob_id == "mob_rare_ashmoor_kingpin":
			rare = mobs[id]
	assert_not_null(rare, "the Ashmoor rare spawns")
	assert_lt(rare.spawn_chance, 1.0, "the rare is a low-probability spawn")
	assert_gt(rare.respawn_ticks, _SC.MOB_RESPAWN_TICKS, "the rare authors a long respawn dwell")
	# T-620: xp is now the WoW-shape formula (mobLevel*5+45), doubled for elite — no more flat
	# authored bounty. The Ashmoor rare is L24 + elite, so it still pays a real burst well above an
	# ordinary low-level trash kill (a L3 wolf: 3*5+45 = 60 XP).
	assert_eq(rare.xp, (rare.mob_level * 5 + 45) * 2, "elite formula, doubled")
	assert_gt(rare.xp, 60 * 3, "still a burst well above an ordinary low-level trash kill")


# ---- next_respawn_ticks: the variable-ratio timer ------------------------------------------


func test_ordinary_mob_returns_its_base_dwell_exactly() -> void:
	var rng := _make_rng(1)
	var m = _mob(1.0, 600)
	# spawn_chance >= 1.0 must never draw the rng and must return the base dwell unchanged.
	for _i in range(20):
		assert_eq(_ML.next_respawn_ticks(m, rng), 600, "ordinary mob = base dwell, no roll")


func test_rare_return_is_a_bounded_multiple_of_the_base_dwell() -> void:
	var rng := _make_rng(7)
	var base := 2400
	var m = _mob(0.2, base)
	var cap := _ML._RARE_CYCLE_CAP
	for _i in range(200):
		var t: int = _ML.next_respawn_ticks(m, rng)
		# Never EARLY (>= one full dwell), always a whole number of dwells, never strands past the cap.
		assert_gte(t, base, "a rare never returns before one full dwell")
		assert_eq(t % base, 0, "a rare return is a whole number of dwells")
		assert_lte(t, base * cap, "a rare return is bounded by the cycle cap")


func test_rare_is_unpredictable_but_averages_near_geometric_mean() -> void:
	# A geometric(spawn_chance) number of dwells => mean cycles ~ 1/chance (bounded by the cap).
	# Assert the empirical mean lands in a sane window AND that the distribution actually VARIES
	# (the whole point of variable-ratio: not a fixed interval).
	var rng := _make_rng(99)
	var chance := 0.25
	var base := 2400
	var m = _mob(chance, base)
	var n := 4000
	var total := 0
	var seen := {}
	for _i in range(n):
		var t: int = _ML.next_respawn_ticks(m, rng)
		total += t
		seen[t] = true
	var mean_cycles := float(total) / float(n) / float(base)
	# Cap truncates the tail so the empirical mean sits a little below the ideal 1/chance = 4.
	assert_between(mean_cycles, 2.5, 4.0, "mean dormant cycles ~ 1/chance, cap-truncated")
	assert_gt(seen.size(), 4, "the return interval VARIES (variable-ratio, not a fixed cadence)")


func test_degenerate_zero_chance_forces_a_return_at_the_cap() -> void:
	# spawn_chance 0 must NOT mean "never respawns" — it floors to a forced return at the cap.
	var rng := _make_rng(3)
	var m = _mob(0.0, 600)
	var cap := _ML._RARE_CYCLE_CAP
	assert_eq(_ML.next_respawn_ticks(m, rng), 600 * cap, "zero chance returns at the forced cap")
