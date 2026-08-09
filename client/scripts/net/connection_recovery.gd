extends RefCounted

const GatewayLogin = preload("res://scripts/net/gateway_login.gd")


func recover(owner: Node, notice: Dictionary) -> void:
	if DisplayServer.get_name() == "headless":
		owner.call("_fail", GatewayLogin.disconnect_message(notice))
		return
	GatewayLogin.queue_disconnect_notice(notice)
	owner.set("_connected", false)
	owner.set("_token", "")
	owner.get_tree().get_multiplayer().set_multiplayer_peer(null)
	owner.call("_setup_networking")
