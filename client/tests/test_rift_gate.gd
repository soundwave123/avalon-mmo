extends GutTest

# T-347: the era-rift threshold trigger. rift_gate.gd is a pure proximity state machine (the
# crypt_gate.gd sibling) — these tests drive it with injected ground positions and assert it fires
# enter_era / leave_era exactly once per crossing, with correct debounce.

const RiftGate = preload("res://scripts/world/rift_gate.gd")

const VAULT := Vector2(424.3, -45.3)  # RiftGate.ENTER_POINT — crypt Vault monolith
const ARRIVAL := Vector2(-420.0, -10.0)  # RiftGate.EXIT_POINT — Ashmoor arrival monolith
const FAR := Vector2(0.0, 0.0)  # village core — near neither monolith


func test_starts_in_era1() -> void:
	var g := RiftGate.new()
	assert_false(g.in_ashmoor)
	assert_eq(g.update(FAR), "")


func test_touch_vault_monolith_fires_enter_once() -> void:
	var g := RiftGate.new()
	assert_eq(g.update(FAR), "")
	assert_eq(g.update(VAULT), "enter_era")
	assert_true(g.in_ashmoor)
	# standing on the monolith does NOT re-fire (server has teleported us to Ashmoor)
	assert_eq(g.update(VAULT), "")


func test_full_round_trip() -> void:
	var g := RiftGate.new()
	assert_eq(g.update(VAULT), "enter_era")
	# server drops us at the Ashmoor arrival plaza (ASHMOOR_ARRIVAL (-420,-5), N of the monolith,
	# > RADIUS from the arrival monolith itself) — no leave yet
	assert_eq(g.update(Vector2(-420.0, -5.0)), "")
	# touch the arrival monolith -> the dev return fires once
	assert_eq(g.update(ARRIVAL), "leave_era")
	assert_false(g.in_ashmoor)
	assert_eq(g.update(ARRIVAL), "")


func test_return_puts_us_clear_no_instant_recross() -> void:
	var g := RiftGate.new()
	g.update(VAULT)  # enter
	g.update(Vector2(-420.0, -5.0))  # arrival plaza (rearms the arrival monolith)
	g.update(ARRIVAL)  # leave -> server drops us at RIFT_RETURN (420,-41.5), the Vault surface
	# RIFT_RETURN is > RADIUS from the Vault monolith (424.3,-45.3), so no immediate re-cross
	assert_eq(g.update(Vector2(420.0, -41.5)), "")
	assert_false(g.in_ashmoor)


func test_recross_after_walking_away_and_back() -> void:
	var g := RiftGate.new()
	g.update(VAULT)
	g.update(Vector2(-420.0, -5.0))  # arrival plaza (rearms the arrival monolith)
	g.update(ARRIVAL)  # leave -> now back in Era 1, in_ashmoor = false
	assert_eq(g.update(FAR), "")  # walk well away (rearms the Vault monolith)
	assert_eq(g.update(VAULT), "enter_era")  # approach the Vault again -> fires


func test_arrival_monolith_ignored_while_in_era1() -> void:
	var g := RiftGate.new()
	# standing on the Ashmoor arrival monolith while NOT in Ashmoor must never fire leave
	assert_eq(g.update(ARRIVAL), "")
	assert_false(g.in_ashmoor)
