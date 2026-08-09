extends GutTest

const LoginRateLimiter = preload("res://scripts/login_rate_limiter.gd")


func test_five_failures_allowed_then_same_ip_is_blocked() -> void:
	var limiter := LoginRateLimiter.new(5, 60_000)
	for attempt in range(5):
		assert_true(limiter.can_attempt("203.0.113.8", 1_000 + attempt))
		limiter.record_failure("203.0.113.8", 1_000 + attempt)
	assert_false(limiter.can_attempt("203.0.113.8", 2_000))


func test_limits_are_per_ip_not_per_websocket_connection() -> void:
	var limiter := LoginRateLimiter.new(2, 60_000)
	limiter.record_failure("198.51.100.4", 10)
	limiter.record_failure("198.51.100.4", 20)
	assert_false(limiter.can_attempt("198.51.100.4", 30), "reconnect keeps the source-IP failures")
	assert_true(limiter.can_attempt("198.51.100.5", 30), "another source gets its own budget")


func test_window_expiry_restores_attempt_budget() -> void:
	var limiter := LoginRateLimiter.new(1, 60_000)
	limiter.record_failure("192.0.2.7", 500)
	assert_false(limiter.can_attempt("192.0.2.7", 60_499))
	assert_true(limiter.can_attempt("192.0.2.7", 60_500))
