extends Node


func _ready():
	var peer = ENetMultiplayerPeer.new()
	for port in [9200, 9300, 19200]:
		var err = peer.create_server(port, 16)
		print("port %d err: %d" % [port, err])
	get_tree().quit.bind(0).call_deferred()
