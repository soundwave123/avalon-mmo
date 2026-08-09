class_name OpsStore
extends RefCounted

# Master-owned durable authority for T-511. Every accepted public verb inserts one append-only row.
# Ban composes the T-501 account flag with that audit insert in ONE Postgres statement.
const CharacterManager = preload("res://scripts/character_manager.gd")
const ACTIONS := ["who", "announce", "broadcast", "msg_group", "whisper", "kick", "ban"]


static func apply(params: Dictionary, query: Callable = Callable()) -> Dictionary:
	var actor := str(params.get("actor", "")).strip_edges().left(80)
	var action := str(params.get("action", ""))
	var target := str(params.get("target", "")).strip_edges().left(128)
	var reason := str(params.get("reason", "")).strip_edges().left(1000)
	var details: Variant = params.get("details", {})
	if actor == "" or not ACTIONS.has(action) or not (details is Dictionary):
		return {"ok": false, "error": "invalid_audit_action"}
	var run := query if query.is_valid() else Callable(CharacterManager, "db_query")
	var rows: Array
	if action == "ban":
		# T-546: the GM types the CHARACTER NAME shown in /who (T-507), not the login. Resolve it to
		# the OWNING account via chars.characters (the canonical name->username seam used by
		# character_manager/character_roster), then disable that account so EVERY alt is locked out —
		# a ban is a person-level action. account_exists reflects whether the character name resolved,
		# so an unknown name returns an honest failure instead of a false ok. The audit row stays
		# keyed on $2 (the character name the GM acted on) for traceability.
		rows = (run.call(
			(
				"WITH resolved AS (SELECT username FROM chars.characters "
				+ "WHERE name = $2 AND deleted_at IS NULL LIMIT 1), "
				+ "disabled AS (UPDATE auth.accounts SET is_active = false "
				+ "WHERE username IN (SELECT username FROM resolved) RETURNING username), "
				+ "revoked_sessions AS (UPDATE auth.sessions SET revoked = true "
				+ "WHERE username IN (SELECT username FROM resolved) RETURNING token), "
				+ "revoked_tokens AS (INSERT INTO "
				+ "auth.session_tokens (token, revoked, revoked_at) SELECT token, true, NOW() "
				+ "FROM revoked_sessions ON CONFLICT (token) DO UPDATE SET revoked = true, "
				+ "revoked_at = NOW() RETURNING token), audit AS (INSERT INTO ops.audit_log "
				+ "(actor, action, target, reason, details) VALUES ($1, $3, $2, $4, $5::jsonb) "
				+ "RETURNING id) SELECT audit.id AS audit_id, "
				+ "EXISTS (SELECT 1 FROM resolved) AS account_exists, "
				+ "EXISTS (SELECT 1 FROM disabled) AS disabled FROM audit"
			),
			[actor, target, action, reason, JSON.stringify(details)]
		))
	else:
		rows = run.call(
			(
				"INSERT INTO ops.audit_log (actor, action, target, reason, details) "
				+ "VALUES ($1, $2, $3, $4, $5::jsonb) RETURNING id AS audit_id"
			),
			[actor, action, target, reason, JSON.stringify(details)]
		)
	if rows.is_empty():
		return {"ok": false, "error": "audit_write_failed"}
	var row: Dictionary = rows[0]
	return {
		"ok": true,
		"audit_id": int(row.get("audit_id", 0)),
		"account_exists": _db_bool(row.get("account_exists", true)),
		"disabled": _db_bool(row.get("disabled", false)),
	}


static func tail(params: Dictionary, query: Callable = Callable()) -> Dictionary:
	var limit := clampi(int(params.get("limit", 50)), 1, 200)
	var run := query if query.is_valid() else Callable(CharacterManager, "db_query")
	var rows: Array = run.call(
		(
			"SELECT id, actor, action, target, reason, details, created_at "
			+ "FROM ops.audit_log ORDER BY id DESC LIMIT $1"
		),
		[limit]
	)
	return {"ok": true, "rows": rows}


static func _db_bool(value: Variant) -> bool:
	return value if value is bool else str(value).to_lower() in ["t", "true", "1"]
