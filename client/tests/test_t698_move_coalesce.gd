extends GutTest

# T-698 fix 1a: the client coalesces request_move sends to MOVE_SEND_HZ (was one send PER physics
# frame). Local prediction is untouched — the body still moves every frame; only the SEND batches.
# The invariant under test: the SUM of the coalesced deltas equals the total predicted ground
# displacement, so the server (which just adds the delta to the authoritative position) lands in
# the identical spot with far fewer messages. A remote observer only ever sees the 10 Hz broadcast,
# so the reduced send rate is unobservable to anyone else (the netcode-safety argument).

const LocalPlayer = preload("res://scripts/world/local_player.gd")


class FakeNet:
	var sends: Array = []  # each request_move(dx, dy) as Vector2
	var mounted := false

	func request_move(dx: float, dy: float) -> void:
		sends.append(Vector2(dx, dy))

	func _is_mounted() -> bool:
		return mounted


func _player_with_net(fn) -> Object:
	var p = LocalPlayer.new()
	add_child_autofree(p)  # _ready builds the capsule + camera rig
	p.setup(fn)
	return p


func _w(pressed: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_W
	ev.physical_keycode = KEY_W
	ev.pressed = pressed
	return ev


func test_sends_batch_at_move_send_hz_not_per_frame() -> void:
	var fn = FakeNet.new()
	var p = _player_with_net(fn)
	Input.parse_input_event(_w(true))
	Input.flush_buffered_events()
	# 30 physics frames at 120 fps (dt = 1/120). MOVE_SEND_HZ = 20 => one send per ~6 frames, so
	# ~5 sends for 30 frames — NOT one per frame (the whole point). Prediction still ran 30 times.
	var dt := 1.0 / 120.0
	for _i in range(30):
		p._physics_process(dt)
	Input.parse_input_event(_w(false))
	Input.flush_buffered_events()
	assert_lt(fn.sends.size(), 12, "far fewer than one send per physics frame (coalesced)")
	assert_gt(fn.sends.size(), 0, "but the player's motion still reached the server")


func test_coalesced_deltas_sum_to_the_full_predicted_displacement() -> void:
	var fn = FakeNet.new()
	var p = _player_with_net(fn)
	var start: Vector3 = p.global_position
	Input.parse_input_event(_w(true))
	Input.flush_buffered_events()
	var dt := 1.0 / 120.0
	for _i in range(48):
		p._physics_process(dt)
	Input.parse_input_event(_w(false))
	Input.flush_buffered_events()
	for _i in range(12):  # decelerate to rest
		p._physics_process(dt)
	var predicted := Vector2(p.global_position.x - start.x, p.global_position.z - start.z)
	# The conservation invariant: EVERY predicted delta is either already sent OR still sitting in
	# the unflushed accumulator — none is ever dropped. sent + pending == predicted path, so once
	# the final partial window flushes the server lands on exactly the predicted position.
	var summed: Vector2 = p._move_send_accum  # whatever hasn't flushed yet
	for s: Vector2 in fn.sends:
		summed += s
	assert_almost_eq(summed.x, predicted.x, 0.001, "sent+pending dx == predicted x displacement")
	assert_almost_eq(summed.y, predicted.y, 0.001, "sent+pending dy == predicted z displacement")


func test_standing_still_sends_nothing() -> void:
	var fn = FakeNet.new()
	var p = _player_with_net(fn)
	var dt := 1.0 / 120.0
	for _i in range(40):  # no input at all
		p._physics_process(dt)
	assert_eq(
		fn.sends.size(), 0, "a stationary player emits zero move intents (empty windows skip)"
	)
