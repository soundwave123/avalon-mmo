# T-719: the tutorial capstone's 1-5 headcount curve. The load-bearing assertion in this file is
# test_damage_never_scales_with_headcount — it is the executable form of the campaign's rule that a
# newcomer's first grouped content must never be blocked by role or composition scarcity. Scaling
# mob DAMAGE with party size is precisely what manufactures a tank requirement, so a later "just
# make groups a bit harder" edit has to break a test that says why.
extends GutTest

const _TS = preload("res://scripts/combat/trial_scaling.gd")


func test_solo_is_the_authored_tuning() -> void:
	assert_eq(_TS.hp_mult(1), 1.0, "a solo run is exactly what the mob JSONs author")
	assert_eq(_TS.dmg_mult(1), 1.0)


func test_damage_never_scales_with_headcount() -> void:
	for n in range(0, 12):
		assert_eq(_TS.dmg_mult(n), 1.0, "%d players still take the authored swing" % n)


func test_hp_scales_monotonically_across_the_band() -> void:
	var previous := 0.0
	for n in range(_TS.MIN_PLAYERS, _TS.MAX_PLAYERS + 1):
		var mult: float = _TS.hp_mult(n)
		assert_gt(mult, previous, "%d players is a bigger pool than %d" % [n, n - 1])
		previous = mult


func test_hp_growth_is_sub_linear_so_groups_clear_faster() -> void:
	# Five players bring ~5x the damage; the encounter must not bring 5x the HP or grouping would be
	# a tax rather than a reward (and the "bring anyone" promise would be a lie).
	assert_lt(_TS.hp_mult(5), 5.0, "a full group clears faster than a solo player")
	assert_eq(_TS.hp_mult(5), 1.0 + _TS.HP_PER_EXTRA * 4.0)


func test_headcount_clamps_to_the_authored_band() -> void:
	assert_eq(
		_TS.clamp_players(0), 1, "a garbage count clamps UP to solo, never to a free discount"
	)
	assert_eq(_TS.clamp_players(-3), 1)
	assert_eq(_TS.clamp_players(9), 5, "a raid at the churchyard stair is capped at the 5-tuning")
	assert_eq(_TS.hp_mult(9), _TS.hp_mult(5))


func test_params_for_cannot_drift_from_the_individual_curves() -> void:
	for n in range(1, 7):
		var p: Dictionary = _TS.params_for(n)
		assert_eq(int(p["players"]), _TS.clamp_players(n))
		assert_eq(float(p["hp_mult"]), _TS.hp_mult(n))
		assert_eq(float(p["dmg_mult"]), _TS.dmg_mult(n))
