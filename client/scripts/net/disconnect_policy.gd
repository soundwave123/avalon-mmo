extends RefCounted

# T-704: disconnect CLASSIFICATION + player-facing copy — the one place that decides whether a
# dropped connection is worth retrying, and what to tell the player when it is not.
#
# Why this exists: the world server rejects a stale client with `outdated_build` and drops the peer.
# The old recovery path re-entered `_setup_networking()` for EVERY disconnect, so a rejection the
# client can never satisfy became a tight re-login loop (514 cycles / 1.09 MB of log spam observed
# 2026-07-28) with nothing on screen. Retrying a terminal reason is not resilience, it is a storm.
#
# TERMINAL = the same credentials/binary will be refused again, forever (or until the player does
# something outside the game: update, log in again, appeal a ban). Stop, and say why.
# TRANSIENT = the failure is about the network or the server's availability, not about us — a
# capped, backed-off retry is legitimate.
#
# The reason vocabulary is the union of what the servers can actually put on the wire:
#   world  — server/world/scripts/main.gd `handshake_err` (outdated_build, plus every master
#            validation error), `kicked` (logged_in_elsewhere, GM kick/ban), `maintenance`
#   master — server/master/scripts/jwt.gd + session_manager.gd token verdicts
# Anything NOT listed is treated as transient: an unknown reason is more likely a new server-side
# blip than a permanent refusal, and the retry cap keeps the cost of guessing wrong bounded.

# Reasons a retry can never fix. Kept as a Dictionary for O(1) `has()` (GDScript has no set type).
const TERMINAL_REASONS := {
	# T-514 build gate (server/shared/build_gate.gd REJECT_REASON) — needs a new download.
	"outdated_build": true,
	# Session/token verdicts — the token we hold is not going to become valid by re-sending it.
	"invalid_token": true,
	"invalid_session": true,
	"invalid_format": true,
	"invalid_signature": true,
	"invalid_header": true,
	"unsupported_alg": true,
	"invalid_payload": true,
	"missing_exp": true,
	"missing_sub": true,
	"expired": true,
	"revoked": true,
	"wrong_token_type": true,
	"duplicate_token": true,
	"not_authenticated": true,
	"invalid_credentials": true,
	# GM / session-ownership outcomes.
	"banned": true,
	"logged_in_elsewhere": true,
}

# Disconnect KINDS the chat panel records from a trusted server frame (ui/chat_panel.gd).
# All three are operator-driven and deliberate: reconnecting against them is noise, not recovery.
const TERMINAL_KINDS := {"ban": true, "kick": true, "maintenance": true}


static func reason_of(state: Dictionary) -> String:
	return str(state.get("reason", "")).replace("\n", " ").replace("\r", " ").strip_edges()


static func is_terminal(state: Dictionary) -> bool:
	if TERMINAL_KINDS.has(str(state.get("kind", ""))):
		return true
	return TERMINAL_REASONS.has(reason_of(state))


# The message the player reads. Kind-based copy first (it carries the GM's own words), then the
# reason table, then a generic transient line. GatewayLogin.disconnect_message() delegates here so
# the login form and the recovery path can never drift apart.
static func message_for(state: Dictionary) -> String:
	var reason := reason_of(state)
	match str(state.get("kind", "error")):
		"maintenance":
			var suffix := "\n%s" % reason if reason != "" else ""
			return "Server is down for maintenance — back soon.%s" % suffix
		"ban":
			return "Account banned by a Game Master: %s" % reason
		"kick":
			return "Disconnected by a Game Master: %s" % reason
	match reason:
		"outdated_build":
			# Same wording the gateway login already shows for this reason, so a player who hits it
			# at either layer reads one consistent instruction.
			var required := str(state.get("required", "")).strip_edges()
			var line := "Your game is out of date. Download the latest version and relaunch."
			return "%s\nMinimum build: %s" % [line, required] if required != "" else line
		"banned":
			return "Account banned by a Game Master."
		"logged_in_elsewhere":
			return "You were signed out — this account logged in somewhere else."
		"invalid_credentials":
			return "Login failed: invalid credentials."
	if TERMINAL_REASONS.has(reason):  # every remaining terminal reason is a session/token verdict
		return "Your session is no longer valid. Please log in again."
	return "Connection lost. Please try again."
