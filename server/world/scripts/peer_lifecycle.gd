extends RefCounted

const PlayerSessions = preload("res://scripts/player_sessions.gd")


static func drop(
	enet_peer: ENetMultiplayerPeer,
	peer_id: int,
	connected_players: Dictionary,
	handshake_timers: Dictionary,
	on_live_disconnect: Callable
) -> void:
	if connected_players.has(peer_id):
		on_live_disconnect.call(peer_id)
		if enet_peer != null:
			enet_peer.disconnect_peer(peer_id)
		return
	if enet_peer != null:
		enet_peer.disconnect_peer(peer_id)
	PlayerSessions.remove_player(peer_id)
	connected_players.erase(peer_id)
	handshake_timers.erase(peer_id)


static func shutdown(disconnect: Callable, peer_ids: Array, tree: SceneTree) -> void:
	for peer_id in peer_ids:
		disconnect.call(int(peer_id))
	tree.quit.bind(0).call_deferred()


# T-181 duplicate-login kick, carved out of main.gd for T-507 (which re-keys it per ACCOUNT:
# logging in on an alt kicks the main's live peer). Kicks the OLDER peer, never the new,
# preserving its state for reconnect.
static func kick_duplicates(
	account: String,
	new_peer_id: int,
	enet_peer: ENetMultiplayerPeer,
	send_to_peer: Callable,
	release_local_state: Callable
) -> void:
	for old_peer_id in PlayerSessions.find_live_peers_by_account(account, new_peer_id):
		print(
			"[world] dup_login account=%s kick old=%d new=%d" % [account, old_peer_id, new_peer_id]
		)
		PlayerSessions.preserve_on_disconnect(old_peer_id)
		release_local_state.call(old_peer_id)
		send_to_peer.call(old_peer_id, {"type": "kicked", "reason": "logged_in_elsewhere"})
		if enet_peer != null:
			enet_peer.disconnect_peer(old_peer_id)
