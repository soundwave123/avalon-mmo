extends RefCounted

# T-507: multi-character accounts — the MASTER half of character selection.
#
# The gateway owns roster mutation (create/delete/select happen pre-world over the login
# socket); this module owns the server-authoritative RESOLUTION of "which character is this
# session acting as" at validate_session time:
#
#   * A `cid` claim in the signed JWT (stamped by the gateway's char_select after its own
#     ownership check) is RE-validated here against the persisted row — the character must
#     exist, be live (not soft-deleted), and belong to the token's account. Defense in
#     depth: even a mis-issued token can never act as another account's character.
#   * No claim (legacy/dev/harness tokens): 0 live characters -> bootstrap slot 0 via
#     ensure_character (unchanged first-login flow); exactly 1 -> auto-select it (unchanged
#     single-character UX); 2+ -> "character_select_required" (the client must pick).
#
# The resolved CHARACTER NAME becomes the identity string the world session carries through
# the whole RPC surface (pre-migration characters: name == username, so nothing changes).

const _CM := preload("res://scripts/character_manager.gd")
const _SM := preload("res://scripts/session_manager.gd")


# T-672: master-only wrapper — validate the JWT (shared logic, byte-identical across servers)
# and THEN resolve the acting character (master's job). This is where T-507's character
# resolution lives now, keeping session_manager.gd identical everywhere. main.gd and the
# world handshake (via the master RPC) call THIS instead of SessionManager.validate_session.
static func validate_and_resolve(token: String) -> Dictionary:
	var session: Dictionary = _SM.validate_session(token)
	if not bool(session.get("success", false)):
		return session
	var account: String = str(session.get("username", ""))
	var resolved: Dictionary = resolve_session_character(account, int(session.get("cid", 0)))
	if not bool(resolved.get("ok", false)):
		return {"success": false, "reason": str(resolved.get("reason", "unknown_character"))}
	return {
		"success": true,
		"username": account,
		"character_id": int(resolved.get("character_id", -1)),
		"character_name": str(resolved.get("character_name", "")),
	}


# Live (non-deleted) characters of an account, ordered by slot. Read-only roster view.
static func list_characters(account: String) -> Array:
	if _CM.test_mode():
		var out: Array = []
		var rows := _CM.test_characters_ref()
		for name: String in rows:
			var row: Dictionary = rows[name]
			if str(row.get("username", "")) == account and not bool(row.get("deleted", false)):
				out.append(row)
		out.sort_custom(func(a, b): return int(a.get("slot", 0)) < int(b.get("slot", 0)))
		return out
	return _CM.db_query(
		(
			"SELECT id, username, name, slot, class, class_locked, gender, level "
			+ "FROM chars.characters WHERE username = $1 AND deleted_at IS NULL ORDER BY slot"
		),
		[account]
	)


# Resolve the acting character for an authenticated session.
# Returns {ok: true, character_id, character_name} or {ok: false, reason}.
static func resolve_session_character(account: String, cid_claim: int) -> Dictionary:
	if account == "":
		return {"ok": false, "reason": "missing_account"}
	if cid_claim > 0:
		return _resolve_claim(account, cid_claim)
	var roster := list_characters(account)
	if roster.is_empty():
		# Fresh account: bootstrap the slot-0 character (exactly the pre-T-507 first login).
		_CM.ensure_character(account)
		roster = list_characters(account)
		if roster.is_empty():
			return {"ok": false, "reason": "character_bootstrap_failed"}
	if roster.size() > 1:
		return {"ok": false, "reason": "character_select_required"}
	var row: Dictionary = roster[0]
	return {
		"ok": true,
		"character_id": int(row.get("id", -1)),
		"character_name": str(row.get("name", "")),
	}


# ADVERSARIAL GATE: the claim must name a live character OWNED by this account. The row is
# re-read here — the token's word is never the last word on ownership.
static func _resolve_claim(account: String, cid_claim: int) -> Dictionary:
	var row := _CM.get_character_by_id(cid_claim)
	if row.is_empty() or bool(row.get("deleted", false)):
		return {"ok": false, "reason": "unknown_character"}
	if str(row.get("username", "")) != account:
		return {"ok": false, "reason": "character_not_owned"}
	return {
		"ok": true,
		"character_id": int(row.get("id", -1)),
		"character_name": str(row.get("name", "")),
	}
