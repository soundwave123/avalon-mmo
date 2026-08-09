extends RefCounted

# Player session manager — validates JWT tokens from gateway.
#
# Stores peer_id -> player data mapping for active world sessions.
# Validates JWT format on client connection; full signature verification
# is handled by master server via RPC.

# T-327: shared deterministic ground-height field. The server ground plane is (x, y) with z =
# height; z is DERIVED here (the single source of position truth), never wired, never trusted from
# the client. On the protected-flat walked pockets it reads 0.0, so flat gameplay is a no-op.
const _TF = preload("res://scripts/terrain_field.gd")
static var _terrain = null  # lazily built once (FastNoiseLite setup) then reused for every move

# Map of peer_id -> player data
static var _players: Dictionary = {}
static var _tokens_used: Dictionary = {}  # token -> peer_id (prevents reuse)

# T-015: Disconnected session store — token -> {username, last_pos, disconnected_at}
static var _disconnected_sessions: Dictionary = {}


static func validate_token_format(token: String) -> bool:
	"""
	Validate token format. Accepts EITHER:
	- JWT: 3 base64url dot-separated parts (header.payload.signature)
	- 32-char lowercase hex string (^[0-9a-f]{32}$)

	Does NOT verify JWT signature — that's master's job.
	"""
	if token.is_empty():
		return false

	if _is_jwt_format(token):
		return true

	if _is_hex_format(token):
		return true

	return false


static func _is_jwt_format(token: String) -> bool:
	var parts: PackedStringArray = token.split(".")
	if parts.size() != 3:
		return false
	for part in parts:
		if part.is_empty():
			return false
		for i in range(part.length()):
			var c: String = part[i]
			if not c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_":
				return false
	return true


static func _is_hex_format(token: String) -> bool:
	if token.length() != 32:
		return false
	for i in range(token.length()):
		var c: String = token[i]
		if not c in "0123456789abcdef":
			return false
	return true


static func add_player(
	peer_id: int,
	token: String,
	username: String = "",
	pos: Vector3 = Vector3.ZERO,
	account: String = "",
	character_id: int = 0
) -> bool:
	"""
	Register a player in the world session.

	T-507: `username` is the CHARACTER NAME (the gameplay identity that flows through the
	RPC surface); `account` is the login username that owns it (duplicate-login kicks are
	per ACCOUNT — one live character per account). Defaults keep the pre-T-507 1:1 shape.

	Returns true if accepted, false if token is invalid or already used.
	"""
	if not validate_token_format(token):
		return false

	# Prevent token reuse across peers
	if token in _tokens_used:
		return false

	# Set username from master validation, or derive stub from token
	var player_username: String = username if not username.is_empty() else token.substr(0, 8)

	_players[peer_id] = {
		"token": token,
		"username": player_username,
		"account": account if not account.is_empty() else player_username,  # T-507
		"character_id": character_id,  # T-507: master-resolved, never client-asserted
		"connected_at": Time.get_unix_time_from_system(),
		"pos": pos,
		# T-331: soft-instance scope. 0 = the shared open world (unchanged broadcast); a non-zero id
		# = a Hollowed Crypt instance. instance_manager.gd owns membership truth; this mirrors it so
		# the positions broadcast can bucket peers without a second lookup.
		"instance_id": 0,
		"mounted": false,  # T-431: server-owned movement mode (never read from client wire)
		"mount_visual": "",  # T-375 cosmetic id; display only, never a speed source
		"warp_seq": 0,  # T-586: bumped on every non-walked reposition (fall-detector suppression)
	}
	_tokens_used[token] = peer_id

	return true


static func get_player(peer_id: int) -> Dictionary:
	"""Get player data by peer_id. Returns empty dict if not found."""
	var player: Dictionary = _players.get(peer_id, {})
	return player.duplicate() if player is Dictionary else {}


static func get_player_view(peer_id: int) -> Dictionary:
	"""T-698: NO-COPY read for trusted internal hot paths (per-mob AI snapshot, per-move intake,
	per-kill-recipient username reads). The returned Dictionary is the LIVE session record —
	callers must treat it as read-only; any path that mutates or holds the dict uses get_player()."""
	var player: Dictionary = _players.get(peer_id, {})
	return player if player is Dictionary else {}


# T-716: the in-world name step renames the acting character MID-SESSION. `username` here IS the
# character name (T-507) and it is the key every master round-trip addresses (quests, XP, rested,
# kill credit, durability), so the live session record has to follow or every later call would
# address a name that no longer exists. The preserved reconnect record follows too, so a rename
# immediately before a drop doesn't restore the dead name. Returns false for an unknown peer or an
# empty name (never blanks a live identity).
static func rename_player(peer_id: int, new_name: String) -> bool:
	if new_name == "" or not _players.has(peer_id):
		return false
	_players[peer_id]["username"] = new_name
	var token: String = str(_players[peer_id].get("token", ""))
	if _disconnected_sessions.has(token):
		_disconnected_sessions[token]["username"] = new_name
	return true


static func update_position(peer_id: int, new_pos: Vector3, walked: bool = false) -> void:
	"""Update the position of a player. Silent no-op if peer not found.

	T-586: `walked` marks the request_move intake — the ONE legitimate movement path. Every
	other caller (rift/instance transfer, flight arrival, BG launch/return, respawn, resurrect)
	is a warp and bumps warp_seq, so the fall detector drops any open descent run and
	re-baselines: a warp can never register as a fall. Default false = warp (safe for any
	future reposition path)."""
	if not _players.has(peer_id):
		return
	# T-327: derive the ground height (z) from the shared field. Movement stays PLANAR-authoritative
	# on (x, y) — this only records the ground under the player (0.0 on every walked-flat pocket).
	if _terrain == null:
		_terrain = _TF.new()
	new_pos.z = _terrain.height(new_pos.x, new_pos.y)
	var player: Dictionary = _players[peer_id]
	player["pos"] = new_pos
	if not walked:
		player["warp_seq"] = int(player.get("warp_seq", 0)) + 1


static func set_instance(peer_id: int, instance_id: int) -> void:
	"""T-331: move a live session into a soft-instance scope (0 = open world). No-op if absent."""
	if _players.has(peer_id):
		_players[peer_id]["instance_id"] = instance_id


static func get_instance(peer_id: int) -> int:
	"""T-331: the soft-instance scope of a session (0 = open world; 0 if the peer is unknown)."""
	return int(_players.get(peer_id, {}).get("instance_id", 0))


static func set_mount_state(peer_id: int, mounted: bool, visual: String) -> void:
	"""T-431: publish server-owned mount state into the existing positions snapshot seam."""
	if _players.has(peer_id):
		_players[peer_id]["mounted"] = mounted
		_players[peer_id]["mount_visual"] = visual if mounted else ""


static func get_positions() -> Dictionary:
	"""
	Return position snapshot of all players.
	Returns Dictionary of peer_id -> {username, x, y, z}.
	"""
	var result: Dictionary = {}
	for pid in _players.keys():
		var player: Dictionary = _players[pid]
		var pos: Vector3 = player.get("pos", Vector3.ZERO)
		result[pid] = {
			"username": player.get("username", ""),
			"x": pos.x,
			"y": pos.y,
			"z": pos.z,  # T-052: height (0 on the flat M3 ground; client remaps to Godot y-up)
			"instance_id": int(player.get("instance_id", 0)),  # T-331: broadcast bucket key
			"mounted": bool(player.get("mounted", false)),
			"mount_visual": str(player.get("mount_visual", "")),
		}
	return result


static func remove_player(peer_id: int) -> void:
	"""Remove a player from the session."""
	var player: Dictionary = _players.get(peer_id, {})
	if player is Dictionary and not player.is_empty():
		var token: String = player.get("token", "")
		_tokens_used.erase(token)
	_players.erase(peer_id)


static func list_players() -> Dictionary:
	"""Return copy of all active players."""
	var result: Dictionary = {}
	for peer_id in _players:
		result[peer_id] = _players[peer_id].duplicate()
	return result


static func find_live_peers_by_username(username: String, exclude_peer_id: int = -1) -> Array[int]:
	"""
	T-181: peer_ids of LIVE (active) sessions whose username matches, excluding one peer.

	Scans ONLY the active _players map — a stale disconnected session (a crashed peer preserved
	in _disconnected_sessions, T-015) is never returned, so reconnect-after-crash is never
	mis-kicked. Empty username matches nothing (a stub/unresolved login can't own an account).
	"""
	var matches: Array[int] = []
	if username.is_empty():
		return matches
	for peer_id in _players:
		if peer_id == exclude_peer_id:
			continue
		if _players[peer_id].get("username", "") == username:
			matches.append(peer_id)
	return matches


# T-507: LIVE peers of an ACCOUNT (any character) — the duplicate-login kick is per account,
# so logging in on an alt kicks the main. Sessions registered without an explicit account
# (legacy/test paths) fall back to username, preserving the T-181 shape. Same stale-session
# discipline as the finder above; empty account matches nothing.
static func find_live_peers_by_account(account: String, exclude_peer_id: int = -1) -> Array[int]:
	var matches: Array[int] = []
	if account.is_empty():
		return matches
	for peer_id in _players:
		if peer_id == exclude_peer_id:
			continue
		var player: Dictionary = _players[peer_id]
		if str(player.get("account", player.get("username", ""))) == account:
			matches.append(peer_id)
	return matches


static func _reset_for_test() -> void:
	"""Clear state between tests."""
	_players.clear()
	_tokens_used.clear()
	_disconnected_sessions.clear()


# ---- T-015: Session lifecycle (disconnect/reconnect) ----


static func preserve_on_disconnect(peer_id: int) -> void:
	"""
	Called when a peer disconnects. Removes the player from active sessions
	and preserves their data in _disconnected_sessions for potential reconnection.

	The token is released from _tokens_used so it can be reused on reconnect.
	"""
	var player: Dictionary = _players.get(peer_id, {})
	if player is Dictionary and not player.is_empty():
		var token: String = player.get("token", "")
		var username: String = player.get("username", "")
		var pos: Vector3 = player.get("pos", Vector3.ZERO)

		# Release token for reuse
		_tokens_used.erase(token)

		# Remove from active players
		_players.erase(peer_id)

		# Store in disconnected sessions
		_disconnected_sessions[token] = {
			"username": username,
			"account": player.get("account", username),  # T-507
			"character_id": int(player.get("character_id", 0)),  # T-507
			"last_pos": pos,
			"disconnected_at": Time.get_unix_time_from_system(),
		}


static func restore_session(token: String) -> Dictionary:
	"""
	Look up a disconnected session by token. Returns and removes the entry
	(consumes it — prevents double-restore). Returns empty dict if not found.
	"""
	if not token in _disconnected_sessions:
		return {}

	var session: Dictionary = _disconnected_sessions[token].duplicate()
	_disconnected_sessions.erase(token)
	return session


static func cleanup_expired(max_age_seconds: float) -> int:
	"""
	Remove disconnected sessions older than max_age_seconds.
	Returns the number of sessions cleaned up.
	"""
	var now: float = Time.get_unix_time_from_system()
	var to_remove: Array[String] = []

	for token in _disconnected_sessions:
		var session: Dictionary = _disconnected_sessions[token]
		var disconnected_at: float = session.get("disconnected_at", now)
		if (now - disconnected_at) > max_age_seconds:
			to_remove.append(token)

	for token in to_remove:
		_disconnected_sessions.erase(token)

	return to_remove.size()


static func _age_session(token: String, seconds_ago: float) -> void:
	"""Test helper: set a session's disconnected_at to N seconds ago."""
	if token in _disconnected_sessions:
		var session: Dictionary = _disconnected_sessions[token]
		session["disconnected_at"] = Time.get_unix_time_from_system() - seconds_ago
		_disconnected_sessions[token] = session

# T-071: the T-016 per-peer resource store that used to live here was a dead parallel twin
# of main.gd._combat_resources (nothing in the live loop called it) — deleted. The live
# store is main.gd._combat_resources; per-tick dynamics live in combat/resource_ticker.gd.
