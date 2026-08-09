# T-382: per-peer intent budget — a token bucket for the master-round-trip intents. Clock is
# injected (now_ms) so the whole thing is unit-testable without OS time.

extends GutTest

const _IRL = preload("res://scripts/intent_rate_limiter.gd")


func test_burst_within_capacity_allowed() -> void:
	var lim = _IRL.new()
	# A UI panel open fires several intents at once — the burst allowance must absorb it.
	for i in range(int(_IRL.CAPACITY)):
		assert_true(lim.allow(7, 0), "intent %d within the burst capacity must pass" % i)


func test_flood_past_capacity_throttled() -> void:
	var lim = _IRL.new()
	for i in range(int(_IRL.CAPACITY)):
		lim.allow(7, 0)  # drain the burst at t=0
	assert_false(lim.allow(7, 0), "over-capacity intent in the same instant must be throttled")


func test_refill_restores_budget_over_time() -> void:
	var lim = _IRL.new()
	for i in range(int(_IRL.CAPACITY)):
		lim.allow(7, 0)
	assert_false(lim.allow(7, 0), "drained")
	# One second later the bucket has refilled REFILL_PER_SEC tokens — legit low-rate play resumes.
	assert_true(lim.allow(7, 1000), "a full second later the refilled budget allows an intent")


func test_sustained_flood_flags_disconnect() -> void:
	var lim = _IRL.new()
	# A tight loop hammering intents in the same instant (no refill): drains the burst, then every
	# further intent is a reject. Past the leaky mark the peer is flagged for disconnect.
	var flagged := false
	for i in range(2000):
		lim.allow(9, 0)
		if lim.should_disconnect(9):
			flagged = true
			break
	assert_true(flagged, "CRIT: a sustained intent flood was never flagged for disconnect")


func test_legit_low_rate_never_disconnects() -> void:
	var lim = _IRL.new()
	# One metered intent per second for two minutes (generous UI cadence) — never throttled, never
	# flagged. This is the tuning guard: real play must not trip the limiter.
	for sec in range(120):
		assert_true(lim.allow(3, sec * 1000), "1 intent/sec must always pass")
		assert_false(lim.should_disconnect(3), "legit play must never be flagged as a flood")


func test_rare_overburst_leaks_and_never_disconnects() -> void:
	var lim = _IRL.new()
	# A bursty-but-legit client: spend the whole burst, get a handful of rejects, then go quiet. The
	# reject counter must leak away so an occasional over-burst never accumulates to a kick.
	for i in range(int(_IRL.CAPACITY) + 10):
		lim.allow(5, 0)  # 10 rejects
	assert_false(lim.should_disconnect(5), "a handful of rejects is not a flood")
	# 30 s of quiet — the leak fully drains the reject counter.
	assert_true(lim.allow(5, 30000), "budget refilled after the quiet window")
	assert_false(lim.should_disconnect(5), "rejects must have leaked away")


func test_peers_have_independent_budgets() -> void:
	var lim = _IRL.new()
	for i in range(int(_IRL.CAPACITY) + 5):
		lim.allow(1, 0)
	assert_true(lim.allow(2, 0), "peer 2 unaffected by peer 1's flood")


func test_forget_clears_state() -> void:
	var lim = _IRL.new()
	for i in range(2000):
		lim.allow(1, 0)
	assert_true(lim.should_disconnect(1), "peer 1 flagged")
	lim.forget(1)
	assert_false(lim.should_disconnect(1), "forgotten peer starts clean")
	assert_true(lim.allow(1, 0), "and has a fresh burst budget")
