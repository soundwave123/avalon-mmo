extends GutTest

# T-704: a rejected login must STOP and say why, not re-login forever.
#
# The bug these tests lock down: `outdated_build` (a rejection no retry can ever satisfy) drove an
# unbounded re-login loop — 514 world rejections and 1.09 MB of "Signal ... is already connected"
# spam in ~60 s, with nothing shown to the player. Three properties prevent it: terminal reasons
# block the token, transient reasons are capped + backed off, and the signal wiring is idempotent.

const ConnectionRecovery = preload("res://scripts/net/connection_recovery.gd")
const DisconnectPolicy = preload("res://scripts/net/disconnect_policy.gd")
const GatewayLogin = preload("res://scripts/net/gateway_login.gd")


class StubOwner:
	extends Node
	var chat_panel = null
	var setups := 0
	var fails: Array = []
	var _connected := true
	var _token := "stale-token"
	var _awaiting := true
	var _elapsed := 9.0

	func _setup_networking(_token_override := "", _host := "", _port := 0) -> void:
		setups += 1

	func _fail(reason: String) -> void:
		fails.append(reason)


var _recovery: RefCounted = null
var _owner: Node = null


func before_each() -> void:
	GatewayLogin._clear_notice_for_test()
	OS.set_environment("AVALON_TOKEN", "")
	# The storm only ever existed on the player-facing path; GUT runs headless, so turn that path on.
	OS.set_environment("AVALON_RECOVERY_INTERACTIVE", "1")
	_recovery = ConnectionRecovery.new()
	_owner = StubOwner.new()
	add_child_autofree(_owner)
	await get_tree().process_frame


func after_each() -> void:
	OS.set_environment("AVALON_RECOVERY_INTERACTIVE", "")
	OS.set_environment("AVALON_TOKEN", "")


# --- classification ------------------------------------------------------------------------------


func test_terminal_reasons_are_classified_terminal() -> void:
	for reason in [
		"outdated_build",  # T-514 build gate — needs a download, not a retry
		"expired",
		"revoked",
		"invalid_token",
		"invalid_session",
		"invalid_signature",
		"wrong_token_type",
		"duplicate_token",
		"banned",
		"logged_in_elsewhere",
	]:
		assert_true(
			DisconnectPolicy.is_terminal({"reason": reason}), "%s must be terminal" % reason
		)
	for kind in ["ban", "kick", "maintenance"]:
		assert_true(DisconnectPolicy.is_terminal({"kind": kind}), "%s kind must be terminal" % kind)


func test_transient_and_unknown_reasons_stay_retryable() -> void:
	# A bare ENet drop carries no reason at all — that is the ordinary network blip.
	assert_false(DisconnectPolicy.is_terminal({}), "bare drop is transient")
	for reason in ["connection_failed", "master_unreachable", "no_session", "something_new"]:
		assert_false(
			DisconnectPolicy.is_terminal({"reason": reason}), "%s must be transient" % reason
		)


func test_outdated_build_copy_tells_the_player_to_update() -> void:
	var msg := DisconnectPolicy.message_for(
		{"reason": "outdated_build", "required": "2026-08-09T06:58:29Z"}
	)
	assert_string_contains(msg, "out of date")
	assert_string_contains(msg, "Download the latest version")
	assert_string_contains(msg, "2026-08-09T06:58:29Z")
	# Without the server's minimum stamp the instruction still stands on its own.
	assert_string_contains(
		DisconnectPolicy.message_for({"reason": "outdated_build"}), "Download the latest version"
	)


func test_existing_gm_copy_is_unchanged_through_the_delegating_call_site() -> void:
	assert_eq(
		GatewayLogin.disconnect_message({"kind": "kick", "reason": "name policy"}),
		"Disconnected by a Game Master: name policy"
	)
	assert_eq(GatewayLogin.disconnect_message({}), "Connection lost. Please try again.")


# --- retry budget --------------------------------------------------------------------------------


func test_backoff_is_exponential_and_capped() -> void:
	assert_eq(ConnectionRecovery.backoff_secs(1), 1.0)
	assert_eq(ConnectionRecovery.backoff_secs(2), 2.0)
	assert_eq(ConnectionRecovery.backoff_secs(3), 4.0)
	assert_eq(ConnectionRecovery.backoff_secs(4), 8.0)
	assert_eq(ConnectionRecovery.backoff_secs(5), 16.0)
	assert_eq(ConnectionRecovery.backoff_secs(9), 16.0, "never grows past the ceiling")


func test_transient_retries_are_capped_then_give_up() -> void:
	var delays: Array = []
	for i in range(ConnectionRecovery.MAX_ATTEMPTS):
		var plan: Dictionary = _recovery.next_action({}, true)
		assert_eq(str(plan["action"]), "retry", "attempt %d still retries" % (i + 1))
		assert_eq(int(plan["attempt"]), i + 1)
		assert_string_contains(str(plan["message"]), "Reconnecting")
		delays.append(float(plan["delay"]))
	assert_eq(delays, [1.0, 2.0, 4.0, 8.0, 16.0], "exponential backoff between attempts")
	var last: Dictionary = _recovery.next_action({}, true)
	assert_eq(str(last["action"]), "give_up", "the budget is finite — no 514-cycle storm")
	assert_string_contains(str(last["message"]), "Gave up after 5 attempts")
	# Past the cap the client is parked: further drops must not restart the loop.
	assert_eq(str(_recovery.next_action({}, true)["action"]), "ignore")


func test_a_completed_handshake_refills_the_budget() -> void:
	for _i in range(3):
		_recovery.next_action({}, true)
	_recovery.on_session_ok()
	assert_eq(int(_recovery.next_action({}, true)["attempt"]), 1, "budget reset after a real login")


func test_transient_without_credentials_goes_straight_to_the_login_form() -> void:
	var plan: Dictionary = _recovery.next_action({}, false)
	assert_eq(str(plan["action"]), "login")
	assert_string_contains(str(plan["message"]), "Connection lost")


func test_terminal_reason_never_retries() -> void:
	var plan: Dictionary = _recovery.next_action({"reason": "outdated_build"}, true)
	assert_eq(str(plan["action"]), "terminal")
	assert_eq(str(_recovery.next_action({}, true)["action"]), "ignore", "and nothing after it does")


# --- token gating: the actual storm valve --------------------------------------------------------


func test_a_terminal_verdict_blocks_the_ambient_token_until_a_human_logs_in() -> void:
	OS.set_environment("AVALON_TOKEN", "env-token")
	assert_eq(_recovery.resolve_token(""), "env-token", "normally the harness token is used")
	_recovery.next_action({"reason": "outdated_build"}, true)
	assert_eq(_recovery.resolve_token(""), "", "blocked: the client cannot silently re-login")
	# An explicit login (form / character select) is a human action and clears the block.
	assert_eq(_recovery.resolve_token("fresh-token"), "fresh-token")
	assert_eq(_recovery.resolve_token(""), "env-token", "unblocked again")


# --- signal idempotence --------------------------------------------------------------------------


func test_repeated_binding_never_stacks_handlers() -> void:
	var mp := SceneMultiplayer.new()
	# every _setup_networking() re-binds; the peer changes, the MultiplayerAPI object does not
	for _i in range(6):
		_recovery.bind_signals(_owner, mp)
	assert_eq(mp.connected_to_server.get_connections().size(), 1)
	assert_eq(mp.connection_failed.get_connections().size(), 1)
	assert_eq(mp.server_disconnected.get_connections().size(), 1)


# --- end to end through recover() ----------------------------------------------------------------


func test_outdated_build_lands_on_the_login_form_with_the_update_message() -> void:
	OS.set_environment("AVALON_TOKEN", "env-token")
	_recovery.on_handshake_err(
		_owner, {"reason": "outdated_build", "required": "2026-08-09T06:58:29Z"}
	)
	await get_tree().process_frame
	assert_eq(_owner.setups, 1, "exactly ONE re-entry — the login form, not a reconnect")
	assert_eq(_owner.fails.size(), 0, "an interactive client reports, it does not quit")
	assert_string_contains(GatewayLogin._pending_notice, "out of date")
	assert_false(_owner._connected)
	assert_false(_owner._awaiting, "the net timeout must not fire while the form is up")
	# The ENet drop that follows the rejection frame must not re-arm anything.
	_recovery._on_server_disconnected()
	await get_tree().process_frame
	assert_eq(_owner.setups, 1, "the trailing disconnect is ignored — no storm")


func test_headless_client_still_fails_fast_with_the_reason() -> void:
	OS.set_environment("AVALON_RECOVERY_INTERACTIVE", "")  # real harness behaviour
	if DisplayServer.get_name() != "headless":
		pass_test("display present — the headless contract is not under test here")
		return
	_recovery.on_handshake_err(_owner, {"reason": "outdated_build"})
	assert_eq(_owner.setups, 0, "a harness client does not open a login form")
	assert_eq(_owner.fails.size(), 1)
	assert_string_contains(str(_owner.fails[0]), "out of date")
