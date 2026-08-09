extends GutTest

# T-691: the loading screen's pure phase/EWMA estimator. Every timestamp is injected, so the whole
# contract — monotonicity, never-100%-early, overrun-eases-not-stalls, EWMA convergence, the
# user:// calibration round-trip — is provable headless with synthetic timings.

const LoadProgressModel = preload("res://scripts/ui/load_progress_model.gd")

const TEST_CFG := "user://t691_test_calibration.cfg"


func after_each() -> void:
	if FileAccess.file_exists(TEST_CFG):
		DirAccess.remove_absolute(TEST_CFG)


# Drives one full synthetic login: begins/ends every canonical phase with the given durations.
func _run_login(model: LoadProgressModel, durations: Dictionary, t0: int) -> int:
	var t := t0
	for phase: String in LoadProgressModel.PHASES:
		model.begin_phase(phase, t)
		t += int(durations.get(phase, 1000))
		model.end_phase(phase, t)
	return t


func test_seed_defaults_cover_every_phase() -> void:
	for phase: String in LoadProgressModel.PHASES:
		assert_true(LoadProgressModel.SEED_MS.has(phase), "phase %s ships a first-run seed" % phase)


func test_fraction_is_monotonic_and_never_full_before_done() -> void:
	var model := LoadProgressModel.new()
	var t := 1000
	var last := model.fraction(t)
	for phase: String in LoadProgressModel.PHASES:
		model.begin_phase(phase, t)
		# Sample inside the phase, including deep overrun (5x expected) — never backwards.
		var expected := int(LoadProgressModel.SEED_MS[phase])
		for step in [0.25, 0.5, 1.0, 2.0, 5.0]:
			var f := model.fraction(t + int(expected * float(step)))
			assert_true(f >= last, "bar never moves backwards (%s @%sx)" % [phase, step])
			assert_lt(f, 1.0, "never 100%% before every phase has ended (%s)" % phase)
			last = f
		t += expected * 5
		model.end_phase(phase, t)
		last = model.fraction(t)
	assert_true(model.done(), "all phases ended")
	assert_almost_eq(model.fraction(t), 1.0, 0.0001, "done -> the bar completes")


func test_overrun_eases_asymptotically_instead_of_stalling() -> void:
	var model := LoadProgressModel.new()
	model.begin_phase("world", 0)
	var expected := int(LoadProgressModel.SEED_MS["world"])
	var prev := model.fraction(expected)  # at 1x expected
	for mult in [2, 3, 5, 8, 12]:
		var f := model.fraction(expected * mult)
		assert_gt(f, prev, "a %dx overrun still creeps — a stopped bar is the worst outcome" % mult)
		prev = f
	# ...but the phase's slice never saturates: progress stays under the 95% phase ceiling.
	var slice := expected / model.expected_total_ms()
	assert_lt(
		prev, slice * LoadProgressModel.PHASE_CEILING + 0.0001, "overrun respects the ceiling"
	)


func test_item_counts_drive_real_progress_but_respect_the_ceiling() -> void:
	var model := LoadProgressModel.new()
	model.begin_phase("populate", 0)
	var early := model.fraction(10)  # 10ms in — the clock alone says nearly nothing
	model.set_items("populate", 90, 100)
	var counted := model.fraction(11)
	assert_gt(counted, early, "90/100 placed props outrank the elapsed clock")
	model.set_items("populate", 100, 100)
	assert_lt(
		model.fraction(12), 1.0, "even 100/100 items holds under 100%% until the end event lands"
	)


func test_ewma_converges_and_the_eta_error_shrinks_across_logins() -> void:
	# This machine is consistently ~2x slower than the shipped seeds. Each login is what the live
	# screen does: a FRESH model, calibration loaded from disk, one run, calibration saved.
	var truth := {}
	var actual_total := 0.0
	for phase: String in LoadProgressModel.PHASES:
		truth[phase] = int(LoadProgressModel.SEED_MS[phase]) * 2
		actual_total += float(truth[phase])
	var t := 0
	var last_err := INF
	var err := INF
	for login in 4:
		var model := LoadProgressModel.new()
		model.load_calibration(TEST_CFG)  # first run: no file yet — the seeds stand
		err = absf(model.expected_total_ms() - actual_total)
		assert_lt(err, last_err, "login %d predicts better than the one before" % login)
		last_err = err
		t = _run_login(model, truth, t) + 60000
		model.save(TEST_CFG)
	var final := LoadProgressModel.new()
	final.load_calibration(TEST_CFG)
	var final_err: float = absf(final.expected_total_ms() - actual_total)
	assert_lt(final_err, actual_total * 0.15, "a few logins in, the ETA basis is within 15%")


func test_calibration_round_trips_through_user_dir() -> void:
	var trained := LoadProgressModel.new()
	var truth := {}
	for phase: String in LoadProgressModel.PHASES:
		truth[phase] = 4321
	_run_login(trained, truth, 0)
	trained.save(TEST_CFG)
	var loaded := LoadProgressModel.new()
	loaded.load_calibration(TEST_CFG)
	assert_almost_eq(
		loaded.expected_total_ms(),
		trained.expected_total_ms(),
		0.01,
		"the learned expectations survive a restart"
	)
	var fresh := LoadProgressModel.new()
	assert_ne(
		fresh.expected_total_ms(), loaded.expected_total_ms(), "and differ from the raw seeds"
	)


func test_missing_calibration_file_keeps_the_seeds() -> void:
	var model := LoadProgressModel.new()
	var before := model.expected_total_ms()
	model.load_calibration("user://t691_nonexistent.cfg")
	assert_eq(model.expected_total_ms(), before, "first run: shipped seeds stand")


func test_an_afk_or_suspended_phase_is_clamped_before_the_fold() -> void:
	var model := LoadProgressModel.new()
	model.begin_phase("connect", 0)
	model.end_phase("connect", 10 * 60 * 1000)  # laptop lid closed mid-login
	var seed := float(LoadProgressModel.SEED_MS["connect"])
	var want := LoadProgressModel.ALPHA * LoadProgressModel.MAX_OBSERVED_MS
	want += (1.0 - LoadProgressModel.ALPHA) * seed
	var got := model.expected_total_ms() - LoadProgressModel.new().expected_total_ms() + seed
	assert_almost_eq(got, want, 0.01, "the fold saw the clamp, not the ten minutes")


func test_eta_comes_from_remaining_phases_and_an_overrun_counts_zero() -> void:
	var model := LoadProgressModel.new()
	var full := model.eta_secs(0)
	assert_gt(full, 0, "before anything begins, the ETA is the whole expected total")
	model.begin_phase("world", 0)
	var overrun := int(LoadProgressModel.SEED_MS["world"]) * 10
	var later := model.eta_secs(overrun)
	assert_lt(later, full, "an overrunning phase contributes 0 — the ETA never counts UP")
	_run_login(model, {}, overrun)
	assert_eq(model.eta_secs(overrun + 100000), 0, "done -> nothing remaining")


func test_out_of_contract_events_are_ignored() -> void:
	var model := LoadProgressModel.new()
	model.begin_phase("terrain", 0)  # a sub-mark, not a canonical phase
	model.end_phase("terrain", 500)
	model.set_items("nonsense", 5, 10)
	model.end_phase("world", 100)  # end before begin
	assert_eq(model.fraction(1000), 0.0, "unknown/misordered events change nothing")
