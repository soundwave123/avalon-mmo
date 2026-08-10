extends GutTest

# T-376: a returning player must never be nagged with the controls card. OnboardingPrefs keeps the
# show/don't-show DECISION pure (apart from FileAccess) so it is testable headless, and keys the
# "seen" flag by username so two accounts on one machine each get their own first run.

const OnboardingPrefs = preload("res://scripts/ui/onboarding_prefs.gd")

# T-756: the round-trip tests below write the developer's REAL user://onboarding.cfg, keying
# each entry by a fresh `Time.get_ticks_usec()` username. Nothing ever removed them, so the
# file grew by two more dead sections on every single test run — forever — and each run began
# from different on-disk state than the last. The old comment "clean up after" described
# cleanup that did not exist. Snapshot the file and restore it byte-for-byte instead: that
# both stops the growth and makes these tests independent of whatever is already on disk.
var _cfg_existed := false
var _cfg_backup := ""


func before_each() -> void:
	_cfg_existed = FileAccess.file_exists(OnboardingPrefs.CONFIG_PATH)
	_cfg_backup = ""
	if _cfg_existed:
		_cfg_backup = FileAccess.get_file_as_string(OnboardingPrefs.CONFIG_PATH)


func after_each() -> void:
	if _cfg_existed:
		var f := FileAccess.open(OnboardingPrefs.CONFIG_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(_cfg_backup)
			f.close()
	elif FileAccess.file_exists(OnboardingPrefs.CONFIG_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(OnboardingPrefs.CONFIG_PATH))


func test_first_entry_auto_shows_then_never_again() -> void:
	# Brand-new character: not seen -> show it.
	assert_true(
		OnboardingPrefs.should_autoshow_controls(false),
		"a first-time player must be shown the controls card"
	)
	# Once seen: never auto-show again (the help key is the only way back).
	assert_false(
		OnboardingPrefs.should_autoshow_controls(true),
		"a returning player must not be nagged with the controls card"
	)


func test_user_key_normalises_and_falls_back_to_guest() -> void:
	assert_eq(OnboardingPrefs.user_key("  Roy  "), "roy", "usernames trim + lowercase to one key")
	assert_eq(OnboardingPrefs.user_key("ROY"), "roy", "same account resolves to the same key")
	assert_eq(OnboardingPrefs.user_key(""), "guest", "no token -> a stable shared guest bucket")


func test_hint_fires_once_and_suppression_wins() -> void:
	# T-426 pure decision: a hint fires iff hints are enabled AND it never fired before.
	assert_true(OnboardingPrefs.should_show_hint(false, true), "fresh hint + hints on -> fire")
	assert_false(OnboardingPrefs.should_show_hint(true, true), "already fired -> never again")
	assert_false(
		OnboardingPrefs.should_show_hint(false, false), "'hide hints' suppresses new hints"
	)
	assert_false(
		OnboardingPrefs.should_show_hint(true, false), "'hide hints' suppresses everything"
	)


func test_combined_seen_is_account_authoritative_with_device_fallback() -> void:
	# T-550: fire-once is now ACCOUNT-authoritative (server-fed hints_seen) with the per-device
	# user://onboarding.cfg as the offline fallback — either source "seen" suppresses the hint.
	# The account's FIRST character (neither has seen it) still gets every hint.
	assert_false(
		OnboardingPrefs.combined_seen(false, false), "first character on the account: hint fires"
	)
	# An alt: the ACCOUNT already saw it (server-fed) even though THIS device never did -> suppressed.
	assert_true(
		OnboardingPrefs.combined_seen(true, false), "an alt (even on a new device) does not re-nag"
	)
	# The device fallback still suppresses when the server state is unavailable (offline/degraded).
	assert_true(OnboardingPrefs.combined_seen(false, true), "the per-device cache still suppresses")
	# And the pure show-decision folds on top: account-seen + hints on -> do not show.
	assert_false(
		OnboardingPrefs.should_show_hint(OnboardingPrefs.combined_seen(true, false), true),
		"an account that already saw the hint never re-shows it on an alt"
	)


func test_round_trips_hint_flags_and_hints_enabled_per_user() -> void:
	var u := "gut_hint_probe_%d" % (Time.get_ticks_usec())
	assert_false(OnboardingPrefs.has_seen_hint(u, "target"), "an unknown user has seen no hints")
	OnboardingPrefs.mark_hint_seen(u, "target")
	assert_true(OnboardingPrefs.has_seen_hint(u, "target"), "the fired flag persists")
	assert_false(OnboardingPrefs.has_seen_hint(u, "move"), "flags are per hint id")
	assert_false(OnboardingPrefs.has_seen_hint(u + "_other", "target"), "and per user")
	# The suppression setting: defaults ON, round-trips per user.
	assert_true(OnboardingPrefs.hints_enabled(u), "hints default ON for a new player")
	OnboardingPrefs.set_hints_enabled(u, false)
	assert_false(OnboardingPrefs.hints_enabled(u), "'hide hints' persists")
	assert_true(OnboardingPrefs.hints_enabled(u + "_other"), "one user's setting never leaks")


func test_round_trips_seen_flag_per_user() -> void:
	# Use a throwaway user so we don't collide with a real profile; clean up after.
	var u := "gut_probe_%d" % (Time.get_ticks_usec())
	assert_false(OnboardingPrefs.has_seen_controls(u), "an unknown user has not seen the card")
	OnboardingPrefs.mark_controls_seen(u)
	assert_true(OnboardingPrefs.has_seen_controls(u), "the seen flag persists after marking")
	# A DIFFERENT user is unaffected — the flag is per-username, not global.
	assert_false(
		OnboardingPrefs.has_seen_controls(u + "_other"),
		"one user's seen flag must not leak to another account"
	)
