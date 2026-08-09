extends RefCounted

# T-511 reasoned login + T-704 storm fix. Owns EVERYTHING about a dropped world connection:
# classification (Policy), the retry budget, the multiplayer signal wiring, and which token — if
# any — the next `_setup_networking()` is allowed to use.
#
# T-704, the bug this file exists to not have again: `recover()` used to unconditionally call
# `owner.call("_setup_networking")`. On a terminal rejection (`outdated_build`) that re-read
# AVALON_TOKEN from the environment and reconnected instantly, so the world rejected it again — 514
# rejection cycles and 1.09 MB of client-log spam in ~60 s, with nothing on screen. Three rules now
# make that impossible:
#   1. a TERMINAL reason blocks the token (`resolve_token()` returns "") — the client lands on the
#      login form, which renders the reason, and stays there until a human logs in again;
#   2. a TRANSIENT reason retries at most MAX_ATTEMPTS times with exponential backoff, then gives up
#      the same way;
#   3. `bind_signals()` is idempotent, so a reconnect can never stack duplicate handlers (the old
#      code re-`connect()`ed three signals per attempt, which is where the log spam came from).
# The attempt budget resets ONLY on a completed handshake (`on_session_ok`) — resetting it on the
# ENet `connected_to_server` would defeat the cap, because a build-gate storm reconnects fine and is
# refused a layer later.

const GatewayLogin = preload("res://scripts/net/gateway_login.gd")
const Policy = preload("res://scripts/net/disconnect_policy.gd")

const MAX_ATTEMPTS := 5
const BASE_DELAY_SECS := 1.0
const MAX_DELAY_SECS := 16.0

var _owner: Node = null
var _attempts := 0
# Set by a terminal verdict (or by exhausting the retry budget): suppresses the ambient AVALON_TOKEN
# so the client cannot silently re-login, and makes any further disconnect signal a no-op.
var _blocked := false
# The token a transient retry may reuse (the one the login form / character select handed us). Never
# read from disk or persisted — it lives exactly as long as the session it belongs to.
var _retry_token := ""


static func backoff_secs(attempt: int) -> float:
	return minf(BASE_DELAY_SECS * pow(2.0, float(maxi(attempt, 1) - 1)), MAX_DELAY_SECS)


# The E2E seam: a headless client normally fails fast (a harness has no player to inform), but the
# T-704 storm only ever existed on the player-facing path, so the T-704 E2E forces that path on in
# a headless run. Nothing in a shipped build sets this.
static func is_interactive() -> bool:
	if OS.get_environment("AVALON_RECOVERY_INTERACTIVE") == "1":
		return true
	return DisplayServer.get_name() != "headless"


# Idempotent signal wiring. Called on every `_setup_networking()`; connects at most once per
# MultiplayerAPI object (which survives `set_multiplayer_peer(null)`, hence the old duplicate spam).
# The two failure handlers are METHODS, not lambdas: a fresh lambda is never `is_connected()`-equal
# to the previous one, so a guard around a lambda would stack handlers silently.
func bind_signals(owner: Node, mp: MultiplayerAPI) -> void:
	_owner = owner
	var on_connected := Callable(owner, "_on_connected")
	if not mp.connected_to_server.is_connected(on_connected):
		mp.connected_to_server.connect(on_connected)
	var on_failed := Callable(self, "_on_connection_failed")
	if not mp.connection_failed.is_connected(on_failed):
		mp.connection_failed.connect(on_failed)
	var on_dropped := Callable(self, "_on_server_disconnected")
	if not mp.server_disconnected.is_connected(on_dropped):
		mp.server_disconnected.connect(on_dropped)


# The only source of the client's token. An explicit override (login form / character select) is a
# human action: it clears any block and becomes the retry token. Otherwise the ambient AVALON_TOKEN
# (harness/pilot runs) is used — unless a terminal verdict blocked it.
func resolve_token(token_override: String) -> String:
	if token_override != "":
		_blocked = false
		_attempts = 0
		_retry_token = token_override
		return token_override
	if _blocked:
		return ""
	var env_token := OS.get_environment("AVALON_TOKEN")
	return env_token if env_token != "" else _retry_token


func on_session_ok() -> void:  # handshake_ok: the connection actually works — refill the budget
	_attempts = 0


# handshake_err arrives on the wire just before the world drops the peer. Recover from it directly
# rather than waiting for the ENet drop, which carries no reason at all.
func on_handshake_err(owner: Node, data: Dictionary) -> void:
	recover(
		owner, {"reason": str(data.get("reason", "")), "required": str(data.get("required", ""))}
	)


# Pure decision step (no awaits, no tree): mutates only the retry budget, so a test can walk the
# whole escalation — retry 1..MAX, then give_up — without timers or a live connection.
func next_action(state: Dictionary, has_credentials: bool) -> Dictionary:
	if _blocked:
		return {"action": "ignore", "message": "", "attempt": 0, "delay": 0.0}
	if Policy.is_terminal(state):
		_blocked = true
		_attempts = 0
		return {
			"action": "terminal", "message": Policy.message_for(state), "attempt": 0, "delay": 0.0
		}
	if not has_credentials:  # nothing to retry WITH — hand the player back to the login form
		return {"action": "login", "message": Policy.message_for(state), "attempt": 0, "delay": 0.0}
	_attempts += 1
	if _attempts > MAX_ATTEMPTS:
		_blocked = true
		_attempts = 0
		return {
			"action": "give_up",
			"message": "%s\nGave up after %d attempts." % [Policy.message_for(state), MAX_ATTEMPTS],
			"attempt": 0,
			"delay": 0.0,
		}
	return {
		"action": "retry",
		"message": "Reconnecting… (attempt %d of %d)" % [_attempts, MAX_ATTEMPTS],
		"attempt": _attempts,
		"delay": backoff_secs(_attempts),
	}


func recover(owner: Node, notice: Dictionary) -> void:
	var has_credentials := _retry_token != "" or OS.get_environment("AVALON_TOKEN") != ""
	var plan := next_action(notice, has_credentials)
	var action := str(plan["action"])
	if action == "ignore":
		return
	var message := str(plan["message"])
	print("[client] disconnect %s: %s" % [action, message.replace("\n", " ")])
	if not is_interactive():
		# Harness contract: a headless client reports the reason and exits rather than retrying.
		owner.call("_fail", message)
		return
	_teardown(owner)
	GatewayLogin.queue_notice_text(message)
	if action == "retry":
		var tree := owner.get_tree()
		if tree == null:
			return
		await tree.create_timer(float(plan["delay"])).timeout
		if owner.get_tree() == null or _blocked:  # cancelled by a terminal verdict mid-backoff
			return
	owner.call("_setup_networking")  # terminal/give_up/login: token blocked or absent → login form


func _on_connection_failed() -> void:
	if _owner != null:
		recover(_owner, {"reason": "connection_failed"})


func _on_server_disconnected() -> void:
	var notice: Dictionary = {}
	if _owner == null:
		return
	var panel = _owner.get("chat_panel")  # trusted server frames (GM kick/ban, maintenance) land here
	if panel != null and panel.has_method("disconnect_notice"):
		notice = panel.disconnect_notice()
	recover(_owner, notice)


func _teardown(owner: Node) -> void:
	owner.set("_connected", false)
	owner.set("_token", "")
	owner.set("_awaiting", false)  # else the 15 s net-timeout _fail()s the client during backoff
	owner.set("_elapsed", 0.0)
	var tree := owner.get_tree()
	if tree != null:
		tree.get_multiplayer().set_multiplayer_peer(null)
