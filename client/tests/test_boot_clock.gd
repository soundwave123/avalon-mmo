extends GutTest

# T-705: the first-session funnel measures from PROCESS LAUNCH, so the client has to time its own
# launch → login-submit → world-interactive window and report it once, after the handshake. The
# clock is injectable here (now_ms) precisely so this is testable without a real boot.

const BootClock = preload("res://scripts/net/boot_clock.gd")
const ClientNet = preload("res://scripts/net/client_net.gd")


func before_each() -> void:
	BootClock.reset()


func after_all() -> void:
	BootClock.reset()  # statics outlive the test — never leak a mark into another suite


func test_no_payload_until_both_phases_are_marked() -> void:
	assert_eq(BootClock.timing_payload(), {}, "nothing marked -> nothing reported")
	BootClock.mark_login_submit(12000)
	assert_eq(
		BootClock.timing_payload(), {}, "a half-booted client reports nothing, not a fake zero"
	)


func test_both_phases_report_as_durations_from_process_launch() -> void:
	BootClock.mark_login_submit(12000)
	BootClock.mark_interactive(41000)
	var payload := BootClock.timing_payload()
	assert_eq(int(payload["launch_to_login_ms"]), 12000, "launch is 0, so the mark IS the duration")
	assert_eq(int(payload["login_to_interactive_ms"]), 29000, "the segment after submit")
	assert_eq(payload.size(), 2, "durations only — no wall clock, nothing that dates the session")


func test_only_the_first_login_submit_counts() -> void:
	# Typing the password wrong and resubmitting is not a second launch→login phase.
	BootClock.mark_login_submit(9000)
	BootClock.mark_login_submit(30000)
	BootClock.mark_interactive(45000)
	assert_eq(int(BootClock.timing_payload()["launch_to_login_ms"]), 9000, "first submit wins")


func test_only_the_first_interactive_mark_counts() -> void:
	BootClock.mark_login_submit(1000)
	BootClock.mark_interactive(5000)
	BootClock.mark_interactive(90000)  # e.g. a zone change later in the session
	assert_eq(int(BootClock.timing_payload()["login_to_interactive_ms"]), 4000)


func test_an_absurd_phase_is_clamped_rather_than_reported() -> void:
	# A laptop suspended on the login screen must not hand the cohort a multi-hour "boot".
	BootClock.mark_login_submit(BootClock.MAX_PHASE_MS * 10)
	BootClock.mark_interactive(BootClock.MAX_PHASE_MS * 20)
	var payload := BootClock.timing_payload()
	assert_eq(int(payload["launch_to_login_ms"]), BootClock.MAX_PHASE_MS)
	assert_eq(int(payload["login_to_interactive_ms"]), BootClock.MAX_PHASE_MS)


func test_reset_clears_both_marks() -> void:
	BootClock.mark_login_submit(1000)
	BootClock.mark_interactive(2000)
	BootClock.reset()
	assert_eq(BootClock.timing_payload(), {}, "a fresh process starts with an empty clock")


# ---- the one report that leaves the client ------------------------------------


func _net(sent: Array):
	var n = ClientNet.new()
	n.setup(func(m): sent.append(m), {})
	return n


func test_the_boot_report_is_one_intent_with_the_two_durations() -> void:
	var sent: Array = []
	BootClock.mark_login_submit(12000)
	_net(sent)._report_boot_timing()
	assert_eq(sent.size(), 1, "exactly one report per session")
	assert_eq(str(sent[0]["type"]), "client_boot_timing")
	assert_eq(int(sent[0]["launch_to_login_ms"]), 12000)
	assert_true(
		sent[0].has("login_to_interactive_ms"),
		"reporting marks the interactive phase itself — that IS the moment we have control",
	)


func test_a_client_that_never_reached_the_login_form_reports_nothing() -> void:
	# The headless harness/pilot boots straight into the world; a guessed boot time would be worse
	# than no boot time (it would sit in the cohort median as a fake sub-second launch).
	var sent: Array = []
	_net(sent)._report_boot_timing()
	assert_eq(sent.size(), 0, "no login mark -> no report at all")
