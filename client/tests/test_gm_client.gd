extends GutTest

const ChatFormatter = preload("res://scripts/ui/chat_formatter.gd")
const ChatPanel = preload("res://scripts/ui/chat_panel.gd")
const ClientNet = preload("res://scripts/net/client_net.gd")
const GatewayLogin = preload("res://scripts/net/gateway_login.gd")

var _panel: Control


func before_each() -> void:
	GatewayLogin._clear_notice_for_test()
	_panel = ChatPanel.new()
	add_child_autofree(_panel)
	await get_tree().process_frame
	_panel.setup(func(_intent): pass)


func test_trusted_gm_whisper_has_unmistakable_tag_and_distinct_color() -> void:
	var formatted := ChatFormatter.format_gm("whisper", "Please relog")
	assert_string_contains(str(formatted["msg"]), "[lb]GM] Whisper:")
	assert_eq(formatted["color"], ChatFormatter.COLOR_GM)
	(
		_panel
		. receive(
			{
				"type": "chat",
				"channel": "whisper",
				"from": "Game Master",
				"text": "Please relog",
				"gm": true,
			}
		)
	)
	assert_true(_panel.get_text().contains("[lb]GM] Whisper:"))
	assert_false(_panel.get_text().contains("Game Master:"), "trusted tag owns presentation")


func test_maintenance_beat_hits_chat_banner_and_disconnect_notice() -> void:
	(
		_panel
		. receive(
			{
				"type": "maintenance",
				"remaining_seconds": 120,
				"reason": "deploy",
				"text": "Server maintenance begins 2m — deploy",
			}
		)
	)
	assert_true(_panel.maintenance_active())
	assert_string_contains(_panel.maintenance_banner_text(), "2m")
	assert_string_contains(_panel.get_text(), "Server maintenance")
	assert_eq(_panel.disconnect_notice(), {"kind": "maintenance", "reason": "deploy"})


func test_reasoned_kick_is_retained_for_login_screen() -> void:
	_panel.receive({"type": "kicked", "reason": "name policy", "banned": false})
	assert_eq(_panel.disconnect_notice(), {"kind": "kick", "reason": "name policy"})


func test_network_router_delivers_maintenance_and_kick_to_session_ui() -> void:
	var routed := {}
	var net = ClientNet.new()
	net.setup(func(_message): pass, {"chat": func(payload): routed["chat"] = payload})
	for message in [
		{"type": "maintenance", "remaining_seconds": 30, "reason": "patch"},
		{"type": "kicked", "reason": "policy", "banned": false},
	]:
		routed.clear()
		net.handle_server_message(message)
		assert_eq(routed["chat"], message)


func test_disconnect_copy_covers_kick_ban_and_maintenance() -> void:
	assert_eq(
		GatewayLogin.disconnect_message({"kind": "kick", "reason": "name policy"}),
		"Disconnected by a Game Master: name policy",
	)
	assert_eq(
		GatewayLogin.disconnect_message({"kind": "ban", "reason": "confirmed exploit"}),
		"Account banned by a Game Master: confirmed exploit",
	)
	var maintenance := GatewayLogin.disconnect_message(
		{"kind": "maintenance", "reason": "database patch"}
	)
	assert_string_contains(maintenance, "Server is down for maintenance — back soon")
	assert_string_contains(maintenance, "database patch")


func test_queued_disconnect_notice_is_shown_on_next_login_form() -> void:
	GatewayLogin.queue_disconnect_notice({"kind": "kick", "reason": "AFK cleanup"})
	var login := GatewayLogin.new()
	add_child_autofree(login)
	login.setup("play.avalon.example")
	assert_eq(
		(login.get_node("Frame/VBox/Status") as Label).text,
		"Disconnected by a Game Master: AFK cleanup",
	)
