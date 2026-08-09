extends GutTest

# T-719: the churchyard stair now ROUTES an under-level party into the Shallow Graves (the tutorial
# capstone) instead of denying it — the T-628 dead end. "One door, two dungeons" is only honest if
# the player is TOLD which one they walked into and what the door below opens at; otherwise the game
# silently decided something on their behalf, which is the same class of problem T-575/T-648/T-662
# were filed for. This is the one member of that reply family that is NOT a failure, so it must land
# on the neutral system-message surface and never on the failure toast.
#
# Its own file because test_hud_handlers_result.gd sits at the gdlint max-public-methods cap (the
# same reason that file exists apart from test_client_net.gd — see its header).

const ClientNet = preload("res://scripts/net/client_net.gd")
const HudHandlers = preload("res://scripts/net/hud_handlers.gd")


class _FakeCombat:
	extends RefCounted
	var failures: Array = []  # report_action_failure(msg)
	var notices: Array = []  # report_system_message(msg) — the neutral surface

	func report_action_failure(msg: String) -> void:
		failures.append(msg)

	func report_system_message(msg: String) -> void:
		notices.append(msg)

	func process_event(_d: Dictionary) -> void:
		pass


func _net(combat) -> ClientNet:
	var n = ClientNet.new()
	n.setup(func(_m): pass, HudHandlers.build(null, null, combat))
	return n


func test_the_trial_routing_notice_reaches_the_player() -> void:
	var combat = _FakeCombat.new()
	var n = _net(combat)

	n.handle_server_message({"type": "instance_entered", "kind": "trial", "players": 1})
	assert_eq(combat.notices.size(), 1, "entering the capstone explains itself exactly once")
	assert_eq(combat.failures.size(), 0, "…and nothing failed, so no failure toast")
	assert_string_contains(combat.notices[0], "Shallow Graves", "names the dungeon they are in")
	assert_string_contains(combat.notices[0], "level 12", "names what to come back for")


func test_an_unmapped_instance_kind_says_nothing() -> void:
	# The crypt/Vault/rift thresholds send no notice today; a kind with no authored line must stay
	# silent rather than leak a raw code at the player.
	var combat = _FakeCombat.new()
	var n = _net(combat)
	n.handle_server_message({"type": "instance_entered", "kind": "crypt"})
	assert_eq(combat.notices.size(), 0)
	assert_eq(combat.failures.size(), 0)


func test_a_missing_combat_surface_never_crashes_the_router() -> void:
	var n = ClientNet.new()
	n.setup(func(_m): pass, HudHandlers.build(null, null, null))
	n.handle_server_message({"type": "instance_entered", "kind": "trial"})
	pass_test("a headless/early-boot client with no HUD yet just drops the notice")
