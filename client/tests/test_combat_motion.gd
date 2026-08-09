extends GutTest

# T-307: the procedural combat-motion stand-in for clipless creatures. Pure math (no nodes, no
# clock) — deterministic transform as a function of (event, elapsed). The wiring onto a real
# clipless rig is covered by test_remote_entities.gd; this pins the motion SHAPE.

const CombatMotion = preload("res://scripts/world/combat_motion.gd")


func test_only_combat_events_are_procedural() -> void:
	assert_true(CombatMotion.has_procedural("attack"))
	assert_true(CombatMotion.has_procedural("hit"))
	assert_true(CombatMotion.has_procedural("death"))
	assert_true(CombatMotion.has_procedural("shoot"))  # T-350: firearm recoil
	# cast/respawn/unknown have no creature stand-in (a caster is always a real-clip hero).
	assert_false(CombatMotion.has_procedural("cast"))
	assert_false(CombatMotion.has_procedural("respawn"))
	assert_false(CombatMotion.has_procedural(""))


func test_shoot_recoils_back_and_up() -> void:
	# T-350: rest at t=0, a backward (+Z) kick + muzzle-rise pitch mid-window, back to rest by end.
	assert_almost_eq(CombatMotion.motion("shoot", 0.0)["offset"].z, 0.0, 0.001, "starts at rest")
	var peak := CombatMotion.motion("shoot", CombatMotion.RECOIL_SHOT_DURATION * 0.20)
	assert_gt(peak["offset"].z, 0.05, "the shot kicks the body BACKWARD (+Z)")
	assert_lt(peak["pitch_x"], 0.0, "the muzzle rises (negative pitch) on the kick")
	assert_almost_eq(
		CombatMotion.motion("shoot", CombatMotion.RECOIL_SHOT_DURATION)["offset"].z,
		0.0,
		0.001,
		"settles back to rest at the end"
	)
	assert_false(CombatMotion.is_done("shoot", 0.0), "recoil is live at the start")
	assert_true(
		CombatMotion.is_done("shoot", CombatMotion.RECOIL_SHOT_DURATION + 0.01),
		"recoil releases after its duration (unlike death)"
	)


func test_attack_lunges_forward_then_returns() -> void:
	# Rest at t=0, a real forward (-Z) surge mid-window, back to rest by the end.
	assert_almost_eq(CombatMotion.motion("attack", 0.0)["offset"].z, 0.0, 0.001, "starts at rest")
	var peak_z: float = (
		CombatMotion.motion("attack", CombatMotion.LUNGE_DURATION * 0.30)["offset"].z
	)
	assert_lt(peak_z, -0.2, "surges FORWARD (-Z) near the peak")
	assert_almost_eq(
		peak_z, -CombatMotion.LUNGE_REACH, 0.001, "peak reaches the full lunge distance"
	)
	var end_z: float = CombatMotion.motion("attack", CombatMotion.LUNGE_DURATION)["offset"].z
	assert_almost_eq(end_z, 0.0, 0.001, "settles back to rest at the end")
	assert_eq(CombatMotion.motion("attack", 0.1)["pitch_x"], 0.0, "a lunge never pitches the body")


func test_hit_recoils_backward() -> void:
	var mid: float = CombatMotion.motion("hit", CombatMotion.RECOIL_DURATION * 0.35)["offset"].z
	assert_gt(mid, 0.1, "a hit knocks the body BACKWARD (+Z), opposite the lunge")
	assert_almost_eq(
		CombatMotion.motion("hit", CombatMotion.RECOIL_DURATION)["offset"].z,
		0.0,
		0.001,
		"the recoil releases back to rest"
	)


func test_death_topples_and_holds() -> void:
	var early := CombatMotion.motion("death", 0.0)
	assert_almost_eq(early["pitch_x"], 0.0, 0.001, "upright at the instant of death")
	var mid := CombatMotion.motion("death", CombatMotion.COLLAPSE_DURATION * 0.5)
	assert_gt(mid["pitch_x"], 0.1, "pitching over as it collapses")
	assert_lt(mid["offset"].y, 0.0, "and sinking toward the ground")
	var done := CombatMotion.motion("death", CombatMotion.COLLAPSE_DURATION)
	assert_almost_eq(done["pitch_x"], CombatMotion.COLLAPSE_PITCH, 0.001, "reaches the prone pitch")
	# Held forever: long after the collapse window the pose is still the final prone pose.
	var much_later := CombatMotion.motion("death", CombatMotion.COLLAPSE_DURATION + 100.0)
	assert_almost_eq(
		much_later["pitch_x"], CombatMotion.COLLAPSE_PITCH, 0.001, "corpse holds prone"
	)


func test_is_done_releases_oneshots_but_never_death() -> void:
	assert_false(CombatMotion.is_done("attack", 0.0), "mid-lunge is not done")
	assert_true(CombatMotion.is_done("attack", CombatMotion.LUNGE_DURATION), "lunge releases")
	assert_true(CombatMotion.is_done("hit", CombatMotion.RECOIL_DURATION), "recoil releases")
	# Death is terminal — never reports done (the corpse holds until an explicit respawn clear).
	assert_false(CombatMotion.is_done("death", CombatMotion.COLLAPSE_DURATION), "collapse held")
	assert_false(CombatMotion.is_done("death", 999.0), "still held long after")


func test_negative_elapsed_is_clamped_to_rest() -> void:
	# A caller that injects a slightly-before-start elapsed must not get a NaN/blowup.
	var m := CombatMotion.motion("attack", -1.0)
	assert_almost_eq(m["offset"].z, 0.0, 0.001, "pre-start reads as rest, not garbage")
