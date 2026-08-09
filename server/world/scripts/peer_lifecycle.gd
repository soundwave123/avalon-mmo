extends RefCounted

const PlayerSessions = preload("res://scripts/player_sessions.gd")


# T-704: ENet's plain disconnect RESETS the peer's outgoing queue, so a reason frame written
# immediately before the drop (`handshake_err` for the T-514 build gate, `kicked` for a duplicate
# login or a GM ban) was discarded on the wire — the client saw a bare, reasonless disconnect and
# treated a permanent rejection as a network blip, which is exactly the T-704 reconnect storm.
# `peer_disconnect_later` sends what is already queued FIRST and then disconnects, so the reason
# always arrives. Bounded: ENet still tears the peer down on its own timeout if the client is gone.
static func close_socket(enet_peer: ENetMultiplayerPeer, peer_id: int) -> void:
	if enet_peer == null:
		return
	var packet_peer: ENetPacketPeer = enet_peer.get_peer(peer_id)
	if packet_peer == null:
		return
	packet_peer.peer_disconnect_later(0)


static func drop(
	enet_peer: ENetMultiplayerPeer,
	peer_id: int,
	connected_players: Dictionary,
	handshake_timers: Dictionary,
	on_live_disconnect: Callable
) -> void:
	if connected_players.has(peer_id):
		on_live_disconnect.call(peer_id)
		close_socket(enet_peer, peer_id)
		return
	close_socket(enet_peer, peer_id)
	PlayerSessions.remove_player(peer_id)
	connected_players.erase(peer_id)
	handshake_timers.erase(peer_id)


static func shutdown(disconnect: Callable, peer_ids: Array, tree: SceneTree) -> void:
	for peer_id in peer_ids:
		disconnect.call(int(peer_id))
	tree.quit.bind(0).call_deferred()


# T-181: idempotent per-peer teardown (disconnect + dup-login kick); clears combat/threat caches.
# Carved from main.gd for T-734 headroom (main rides the 1000-line cap); `m` is the world main
# node — the debug_intents.handle(self, ...) idiom for a capped main's stores.
static func release_local_state(m, peer_id: int) -> void:
	m._connected_players.erase(peer_id)
	m._equipped.erase(peer_id)
	m._titles.erase(peer_id)  # T-401
	m._instance_svc.on_peer_gone(peer_id)  # T-331: drop instance membership + free spawns
	m._social_svc.forget(peer_id)  # T-361/T-363: chat window + ignore cache; cancels a live trade
	m._mount_svc.forget(peer_id)
	m._mentor_svc.peer_gone(peer_id)  # T-280/T-452: leave party + restore surviving mentors
	m._handshake_timers.erase(peer_id)
	for c in [m._combat_states, m._combat_resources, m._char_stats, m._char_class]:
		c.erase(peer_id)  # combat/class caches (T-020/T-063)
	m._talent_ability_mods.erase(peer_id)  # T-064
	m._fall.erase(peer_id)  # T-586: drop any open descent run with the session
	m._char_gender.erase(peer_id)  # T-597: persisted-gender cache
	m._move_limiter.forget(peer_id)  # T-074
	m._intent_limiter.forget(peer_id)  # T-382
	if m._telemetry != null:
		m._telemetry.forget_peer(peer_id)  # T-705: once-per-session markers die with the session
	# T-051: a disconnected player must not keep mob aggro or be credited a kill via threat.
	m._threat_table.remove_attacker_everywhere(peer_id)


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
		close_socket(enet_peer, old_peer_id)  # T-704: flush the reason, then drop
