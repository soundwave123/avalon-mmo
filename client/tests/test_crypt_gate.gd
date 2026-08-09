extends GutTest

# T-330: the churchyard-stair threshold trigger. crypt_gate.gd is a pure proximity state machine
# (npc_wander.gd style) — these tests drive it with injected ground positions and assert it fires
# enter_instance / leave_instance exactly once per crossing, with correct debounce.

const CryptGate = preload("res://scripts/world/crypt_gate.gd")

const PORCH := Vector2(14.0, -12.5)  # CryptGate.ENTER_POINT
const VEST := Vector2(420.0, 2.2)  # CryptGate.EXIT_POINT
const FAR := Vector2(0.0, 0.0)  # village core — near neither threshold


func test_starts_outside() -> void:
	var g := CryptGate.new()
	assert_false(g.in_crypt)
	assert_eq(g.update(FAR), "")


func test_step_onto_porch_fires_enter_once() -> void:
	var g := CryptGate.new()
	assert_eq(g.update(FAR), "")
	assert_eq(g.update(PORCH), "enter_instance")
	assert_true(g.in_crypt)
	# standing on the porch does NOT re-fire (server has already teleported us away)
	assert_eq(g.update(PORCH), "")


func test_full_round_trip() -> void:
	var g := CryptGate.new()
	assert_eq(g.update(PORCH), "enter_instance")
	# server drops us in the vestibule (CRYPT_ENTRANCE, far from the exit stair) — no leave yet
	assert_eq(g.update(Vector2(420.0, -1.0)), "")
	# walk back up to the vestibule stair -> leave fires once
	assert_eq(g.update(VEST), "leave_instance")
	assert_false(g.in_crypt)
	assert_eq(g.update(VEST), "")


func test_leaving_puts_us_clear_of_the_porch_no_instant_reenter() -> void:
	var g := CryptGate.new()
	g.update(PORCH)  # enter
	g.update(Vector2(420.0, -1.0))  # server drops us in the vestibule (rearms the exit stair)
	g.update(VEST)  # leave -> server drops us at CRYPT_EXIT (12, -10.5)
	# CRYPT_EXIT is > RADIUS from the porch, so no immediate re-enter
	assert_eq(g.update(Vector2(12.0, -10.5)), "")
	assert_false(g.in_crypt)


func test_reenter_after_walking_away_and_back() -> void:
	var g := CryptGate.new()
	g.update(PORCH)
	g.update(Vector2(420.0, -1.0))  # vestibule (rearms exit)
	g.update(VEST)  # leave -> now outside, in_crypt = false
	assert_eq(g.update(FAR), "")  # walk well away (rearms the porch)
	assert_eq(g.update(PORCH), "enter_instance")  # approach again -> fires


func test_exit_stair_ignored_while_outside() -> void:
	var g := CryptGate.new()
	# standing on the vestibule-stair coord while NOT in a crypt must never fire leave
	assert_eq(g.update(VEST), "")
	assert_false(g.in_crypt)
