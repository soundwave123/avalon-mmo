extends GutTest

# T-623: pure math for the pilot's two "stop lying about success" fixes — goto arrival (#57's
# 50-hop retry loop that got a character killed) and look inertness (session-12's blind ok:true on
# a drag that never turned the camera). See client/scripts/dev/pilot_checks.gd for the rationale;
# the LIVE wiring (does a real hop sequence/drag actually land) is proven in test_pilot.gd.

const PilotChecks = preload("res://scripts/dev/pilot_checks.gd")


func test_goto_arrival_ok_within_tolerance() -> void:
	var r := PilotChecks.goto_arrival(Vector3(10.2, 1.0, -4.9), 10.0, -5.0, 0.5)
	assert_true(r["ok"], "within the 0.5u tolerance -> ok:true")


func test_goto_arrival_exactly_at_tolerance_is_ok() -> void:
	var r := PilotChecks.goto_arrival(Vector3(10.5, 0.0, 0.0), 10.0, 0.0, 0.5)
	assert_true(r["ok"], "exactly AT tolerance counts as arrived (<=, not <)")


func test_goto_arrival_beyond_tolerance_reports_actual_wanted_dist() -> void:
	var r := PilotChecks.goto_arrival(Vector3(0.0, 0.0, 0.0), 10.0, 0.0, 0.5)
	assert_false(r["ok"], "10u short of target -> ok:false")
	assert_eq(r["actual"], [0.0, 0.0], "actual [x,z]")
	assert_eq(r["wanted"], [10.0, 0.0], "wanted [x,z]")
	assert_almost_eq(float(r["dist"]), 10.0, 0.001, "dist matches the straight-line gap")


func test_goto_arrival_ignores_height() -> void:
	# y is irrelevant to arrival — only the ground plane (x,z) matters (matches goto's own semantics
	# of teleporting on the (x,z) plane and setting y separately).
	var r := PilotChecks.goto_arrival(Vector3(10.0, 99.0, 0.0), 10.0, 0.0, 0.5)
	assert_true(r["ok"], "a huge y difference doesn't affect planar arrival")


func test_look_verified_ok_when_yaw_actually_changed() -> void:
	var r := PilotChecks.look_verified(0.0, 0.2, 50.0)
	assert_true(r["ok"], "yaw moved -> ok:true")
	assert_almost_eq(float(r["yaw_delta"]), 0.2, 0.001, "yaw_delta reported")


func test_look_verified_flags_inert_drag() -> void:
	var r := PilotChecks.look_verified(1.0, 1.0, 50.0)
	assert_false(r["ok"], "dx requested a turn but yaw never moved -> ok:false")
	assert_true(str(r["error"]).contains("inert"), "the reason names the inertness")


func test_look_verified_zero_dx_never_flags_a_noop() -> void:
	var r := PilotChecks.look_verified(1.0, 1.0, 0.0)
	assert_true(r["ok"], "dx=0 expects no turn — an unchanged yaw is correct, not inert")
