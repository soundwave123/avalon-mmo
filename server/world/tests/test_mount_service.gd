extends GutTest

# T-431: mount mode is server-owned. The wire toggles a desire only; learned state controls access,
# cosmetic skin changes only the broadcast visual, and combat/damage clears the elevated cap.

const MountService = preload("res://scripts/mount_service.gd")
const ServerConfig = preload("res://scripts/server_config.gd")
const PlayerSessions = preload("res://scripts/player_sessions.gd")
const BroadcastBuilder = preload("res://scripts/broadcast_builder.gd")
const MovementCollision = preload("res://scripts/movement_collision.gd")  # T-572
const MoveRateLimiter = preload("res://scripts/move_rate_limiter.gd")  # T-572

const TOKEN := "dddddddddddddddddddddddddddddddd"  # gitleaks:allow

var _states: Array
var _replies: Array
var _svc


func before_each() -> void:
	_states = []
	_replies = []
	_svc = MountService.new()
	_svc.setup(
		func(pid, mounted, visual):
			_states.append({"pid": pid, "mounted": mounted, "visual": visual}),
		func(pid, msg): _replies.append([pid, msg])
	)


func test_unlearned_profile_rejects_toggle_and_wire_cannot_forge_state() -> void:
	_svc.seed(1, {"learned": false, "mount_id": "", "skin": ""})
	_svc.handle(1, {"action": "toggle", "mounted": true, "speed": 9999}, 0)
	assert_false(_svc.is_mounted(1))
	assert_eq(str(_replies[-1][1]["reason"]), "mount_not_learned")
	assert_eq(_svc.speed_cap(1), ServerConfig.MAX_SPEED_PER_TICK)


# T-658: the riding-trainer purchase must unblock the keypress THIS SESSION — a player who just
# paid the trainer should not have to relog before the "learned" gate lets them mount up.
func test_mark_learned_unblocks_the_keypress_without_a_relog() -> void:
	_svc.seed(6, {"learned": false, "mount_id": "mount_common_gryphon", "skin": ""})
	_svc.handle(6, {"action": "toggle"}, 0)
	assert_false(_svc.is_mounted(6), "still blocked before training")
	assert_eq(str(_replies[-1][1]["reason"]), "mount_not_learned")

	_svc.mark_learned(6)
	_svc.handle(6, {"action": "toggle"}, 0)
	assert_true(_svc.is_mounted(6), "allowed immediately after training clears, no relog needed")


# mark_learned on a peer with no cached profile (never seeded, or already disconnected) is a no-op
# rather than a crash — there's nothing to unblock.
func test_mark_learned_on_an_unseeded_peer_does_not_crash() -> void:
	_svc.mark_learned(999)
	assert_false(_svc.is_mounted(999))


func test_learned_mount_raises_both_server_caps_and_toggle_dismounts() -> void:
	_svc.seed(2, {"learned": true, "mount_id": "mount_common_gryphon", "skin": ""})
	_svc.handle(2, {"action": "toggle"}, 0)
	assert_true(_svc.is_mounted(2))
	assert_eq(_svc.speed_cap(2), ServerConfig.MAX_SPEED_MOUNTED_PER_TICK)
	assert_eq(_svc.units_per_second(2), ServerConfig.MOVE_UNITS_MOUNTED_PER_SECOND)
	_svc.handle(2, {"action": "toggle"}, 0)
	assert_false(_svc.is_mounted(2))


func test_combat_state_blocks_mount_and_damage_dismount_restores_normal_cap() -> void:
	_svc.seed(3, {"learned": true, "mount_id": "mount_common_gryphon", "skin": ""})
	_svc.handle(3, {"action": "toggle"}, 2)  # Casting, not Idle
	assert_false(_svc.is_mounted(3), "cannot mount while casting/in combat state")
	assert_eq(str(_replies[-1][1]["reason"]), "in_combat")
	_svc.handle(3, {"action": "toggle"}, 0)
	assert_true(_svc.is_mounted(3))
	assert_true(_svc.dismount(3, "damage"), "damage knocks the rider off")
	assert_eq(_svc.speed_cap(3), ServerConfig.MAX_SPEED_PER_TICK)
	assert_eq(str(_replies[-1][1]["reason"]), "damage")


func test_skin_swap_changes_visual_without_changing_speed() -> void:
	_svc.seed(
		4, {"learned": true, "mount_id": "mount_common_gryphon", "skin": "skin_storm_gryphon"}
	)
	_svc.handle(4, {"action": "toggle"}, 0)
	var skinned_speed: float = _svc.speed_cap(4)
	assert_eq(str(_states[-1]["visual"]), "skin_storm_gryphon")
	_svc.seed(
		5, {"learned": true, "mount_id": "mount_common_gryphon", "skin": "skin_royal_gryphon"}
	)
	_svc.handle(5, {"action": "toggle"}, 0)
	assert_eq(str(_states[-1]["visual"]), "skin_royal_gryphon")
	assert_eq(_svc.speed_cap(5), skinned_speed, "cosmetic selection never changes mount power")


func test_skin_rides_existing_positions_broadcast_seam_without_power_field() -> void:
	PlayerSessions._reset_for_test()
	PlayerSessions.add_player(9, TOKEN, "rider", Vector3.ZERO)
	var svc = MountService.new()
	svc.setup(Callable(PlayerSessions, "set_mount_state"), func(_pid, _msg): pass)
	svc.seed(9, {"learned": true, "mount_id": "mount_common_gryphon", "skin": "skin_storm_gryphon"})
	svc.handle(9, {"action": "toggle"}, 0)
	var payload: Array = BroadcastBuilder.players_array(PlayerSessions.get_positions(), {}, {})
	assert_true(bool(payload[0]["mounted"]))
	assert_eq(str(payload[0]["mount_visual"]), "skin_storm_gryphon")
	assert_false(payload[0].has("speed"), "cosmetic broadcast never carries movement power")
	PlayerSessions._reset_for_test()


# T-572: mounting was a complete no-op for real players — the caps below were already raised on
# mount (T-431), but nothing ever sent a delta big enough to test them against, because the client's
# own predicted speed never varied with mount state. These pin the real mounted travel speed and
# exercise resolve_move end-to-end (not just the getters) to prove the anti-cheat gate is genuinely
# mount-aware, not just cosmetically so.
func test_real_mounted_run_speed_matches_the_documented_multiplier() -> void:
	assert_almost_eq(
		ServerConfig.PLAYER_RUN_SPEED_MOUNTED,
		ServerConfig.PLAYER_RUN_SPEED * ServerConfig.MOUNT_SPEED_MULT,
		0.0001,
		"9.6 u/s = 6.0 * 1.6"
	)
	# The pre-existing anti-cheat ceiling (T-431) already used exactly this ratio (100 -> 160);
	# T-572 gives the REAL gameplay speed the same multiplier instead of leaving it unmounted-only.
	assert_almost_eq(
		ServerConfig.MAX_SPEED_MOUNTED_PER_TICK / ServerConfig.MAX_SPEED_PER_TICK,
		ServerConfig.MOUNT_SPEED_MULT,
		0.0001,
		"the new real-speed multiplier matches the ceiling's existing tier ratio"
	)


func test_resolve_move_accepts_mounted_tier_speed_but_rejects_it_when_not_mounted() -> void:
	var mounted_svc := MountService.new()
	mounted_svc.setup(func(_p, _m, _v): pass, func(_p, _m): pass)
	mounted_svc.seed(20, {"learned": true, "mount_id": "mount_common_gryphon", "skin": ""})
	mounted_svc.handle(20, {"action": "toggle"}, 0)
	assert_true(mounted_svc.is_mounted(20))
	var collision := MovementCollision.new("")  # no barrier data — isolates the speed/rate gate
	# Between the two tiers (100 unmounted / 160 mounted): legal ONLY while actually mounted.
	var fast := Vector2(150.0, 0.0)
	var res_mounted: Dictionary = mounted_svc.resolve_move(
		collision, Vector2.ZERO, fast, 20, 0, MoveRateLimiter.new()
	)
	assert_true(res_mounted["ok"], "mounted-tier speed is accepted while actually mounted")

	var grounded_svc := MountService.new()
	grounded_svc.setup(func(_p, _m, _v): pass, func(_p, _m): pass)
	grounded_svc.seed(21, {"learned": true, "mount_id": "mount_common_gryphon", "skin": ""})
	# Never toggled -> stays unmounted.
	var res_unmounted: Dictionary = grounded_svc.resolve_move(
		collision, Vector2.ZERO, fast, 21, 0, MoveRateLimiter.new()
	)
	assert_false(
		res_unmounted["ok"], "the SAME speed is rejected as speed-hacking when not mounted"
	)
	assert_eq(str(res_unmounted["reason"]), "speed")

	# Even mounted, a speed above BOTH ceilings is still speed-hacking — mounting raises the tier,
	# it does not disable anti-cheat.
	var absurd := Vector2(500.0, 0.0)
	var res_absurd: Dictionary = mounted_svc.resolve_move(
		collision, Vector2.ZERO, absurd, 20, 1, MoveRateLimiter.new()
	)
	assert_false(res_absurd["ok"], "no speed is legal — mount or not — anti-cheat stays intact")


func test_real_predicted_speeds_from_both_tiers_clear_resolve_move() -> void:
	# The speeds LocalPlayer will now actually send (T-572 client fix), expressed per one server
	# tick — comfortably inside their respective ceiling with plenty of anti-teleport headroom.
	var svc := MountService.new()
	svc.setup(func(_p, _m, _v): pass, func(_p, _m): pass)
	svc.seed(22, {"learned": true, "mount_id": "mount_common_gryphon", "skin": ""})
	var collision := MovementCollision.new("")
	var on_foot_step := Vector2(
		ServerConfig.PLAYER_RUN_SPEED / float(ServerConfig.TICK_RATE_HZ), 0.0
	)
	var res: Dictionary = svc.resolve_move(
		collision, Vector2.ZERO, on_foot_step, 22, 0, MoveRateLimiter.new()
	)
	assert_true(res["ok"], "on-foot real run speed is legal unmounted")
	svc.handle(22, {"action": "toggle"}, 0)
	var mount_step := Vector2(
		ServerConfig.PLAYER_RUN_SPEED_MOUNTED / float(ServerConfig.TICK_RATE_HZ), 0.0
	)
	var res2: Dictionary = svc.resolve_move(
		collision, res["pos"], mount_step, 22, 1, MoveRateLimiter.new()
	)
	assert_true(res2["ok"], "mounted real run speed is legal while mounted")
