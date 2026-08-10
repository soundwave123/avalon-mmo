extends RefCounted

# Session manager — JWT token validation + persistence.
#
# Issues and validates HS256 JWT tokens. Checks against Postgres
# session_tokens table for revocation and lifetime.
#
# FAIL-FAST: Validates JWT signing secret on startup. If missing or
# too short (< 32 bytes), the master server will refuse to start.

const JwtUtil = preload("res://scripts/jwt.gd")

const DB_HOST := "localhost"
const DB_PORT := 5432
const DB_NAME := "avalon"
const DB_USER := "avalon"
const DB_PASS := ""  # unused — pg_query.sh reads AVALON_PG_PASSWORD from env; open_db() is a no-op


static func _get_db_pass() -> String:
	var pw := OS.get_environment("AVALON_PG_PASSWORD")
	return str(pw) if pw != null else ""


# JWT configuration (loaded from environment at runtime)
static var _jwt_secret: String = ""
static var _jwt_ttl_seconds: int = 900  # T-007: 15 min access token
static var _secret_validated: bool = false
static var _test_skip_db: bool = false

# T-007: Refresh token configuration
static var _refresh_secret: String = ""
static var _refresh_secret_validated: bool = false
static var _test_refresh_store: Dictionary = {}  # username -> jti (for in-memory test tracking)


static func init_from_env() -> bool:
	"""
	Read JWT config from environment. Call on startup.
	Returns true if secret validation passes, false otherwise.
	"""
	var secret := OS.get_environment("AVALON_JWT_SECRET")
	if secret != null and not str(secret).is_empty():
		_jwt_secret = str(secret)
	else:
		_jwt_secret = ""

	var ttl := OS.get_environment("AVALON_JWT_TTL_SECONDS")
	if ttl != null and not str(ttl).is_empty():
		_jwt_ttl_seconds = int(str(ttl))

	# FAIL-FAST: Validate secret
	_validate_secret_guard()
	return _secret_validated


static func _validate_secret_guard() -> void:
	"""Validate JWT signing secret meets minimum requirements."""
	if _secret_validated:
		return

	var jwt_util := JwtUtil.new()
	if not jwt_util.validate_secret(_jwt_secret):
		push_error(
			(
				"[master] FATAL: AVALON_JWT_SECRET missing or too short (< 32 bytes). "
				+ "Refusing to start."
			)
		)
		return

	_secret_validated = true
	var secret_bytes: int = _jwt_secret.length()
	print("[master] jwt_secret loaded: %d bytes" % secret_bytes)


static func is_secret_valid() -> bool:
	"""Check if the JWT secret passes validation."""
	var jwt_util := JwtUtil.new()
	return jwt_util.validate_secret(_jwt_secret)


static func check_db_connectivity() -> bool:
	"""Check if Postgres is reachable. Returns true if connected."""
	var db := _get_db()
	if db == null:
		printerr("[session_manager] cannot create DB connection")
		return false
	db.close_db()
	return true


static func issue_session(_username: String, ttl_minutes: int = 120) -> Dictionary:
	"""
	Issue a new JWT session for a user.
	This delegates to the gateway for actual token issuance — the master
	receives the JWT and stores it for revocation tracking.
	"""
	return {"success": true, "ttl_minutes": ttl_minutes}


# ---- T-007: Refresh token rotation ----


static func store_refresh_session(
	username: String, jti: String, access_token: String, refresh_token: String
) -> bool:
	"""
	T-007: Store a new session with refresh_token_id for rotation.

	In test mode, stores in-memory. In production, would INSERT INTO auth.sessions.
	"""
	if _test_skip_db:
		_test_refresh_store[username] = jti
		return true

	var db := _get_db()
	if db == null:
		return false

	var sql := (
		"INSERT INTO auth.sessions (token, username, issued_at, expires_at, revoked, refresh_token_id) "
		+ "VALUES ($1, $2, NOW(), NOW() + INTERVAL '24 hours', false, $3) "
		+ "ON CONFLICT (token) DO UPDATE SET refresh_token_id = $3, expires_at = NOW() + INTERVAL '24 hours'"
	)
	var err: int = db.execute_query(sql, [refresh_token, username, jti])
	if err != OK:
		printerr("[session_manager] failed to store refresh session: %d" % err)
		db.close_db()
		return false

	db.close_db()
	return true


static func rotate_refresh(username: String, old_jti: String) -> Dictionary:
	"""
	T-007: Atomic refresh token rotation.

	Atomic check-and-update: only succeeds if the stored refresh_token_id
	matches old_jti AND the session is not revoked.

	Returns:
		{success: true, username: String} on successful rotation
		{success: false, reason: String} on failure (replayed, expired, revoked)
	"""
	if _test_skip_db:
		# In-memory atomic rotation for testing
		var stored_jti: String = _test_refresh_store.get(username, "")
		if stored_jti != old_jti:
			# Token already consumed or doesn't match → HARD REJECTION
			return {"success": false, "reason": "refresh_token_consumed"}
		# Successful rotation — clear the old jti (next store_refresh_session will set new one)
		_test_refresh_store.erase(username)
		return {"success": true, "username": username}

	var db := _get_db()
	if db == null:
		return {"success": false, "reason": "database_unavailable"}

	# Atomic check-and-update: the security-critical core
	# UPDATE auth.sessions SET refresh_token_id = NULL
	# WHERE username = $1 AND refresh_token_id = $2 AND revoked = false
	# RETURNING username;
	#
	# Setting to NULL marks the token as consumed. Next rotation attempt
	# with the same old_jti will find no matching row → zero rows returned.
	var sql := (
		"UPDATE auth.sessions SET refresh_token_id = NULL "
		+ "WHERE username = $1 AND refresh_token_id = $2 AND revoked = false "
		+ "RETURNING username"
	)
	var err: int = db.execute_query(sql, [username, old_jti])
	if err != OK:
		printerr("[session_manager] rotation query failed: %d" % err)
		db.close_db()
		return {"success": false, "reason": "database_error"}

	var result: Variant = db.query_result()
	db.close_db()

	var rows: Array = result if result is Array else []
	if rows.is_empty():
		# Zero rows returned — token already consumed, revoked, or doesn't exist
		return {"success": false, "reason": "refresh_token_consumed"}

	var first_row: Dictionary = rows[0]
	var returned_username: String = str(first_row.get("username", ""))
	return {"success": true, "username": returned_username}


static func validate_session(token: String) -> Dictionary:
	"""
	Validate a JWT token: check signature, expiry, and revocation. Returns
	{"success": true, "username": String, "cid": int} on valid — `cid` is the decoded
	character claim (0 if absent); the MASTER resolves the acting character from it via
	CharacterRoster.validate_and_resolve (T-507/T-672), keeping this file identical across
	servers. Returns {"success": false, "reason": String} on invalid.
	"""
	# Step 1: JWT signature + expiry check
	var jwt_util := JwtUtil.new()
	var jwt_result: Dictionary = jwt_util.verify(token, _jwt_secret)
	if not jwt_result.get("valid", false):
		return {"success": false, "reason": jwt_result.get("reason", "invalid_token")}

	var payload: Dictionary = jwt_result["payload"]
	var username: String = str(payload.get("sub", ""))

	if username.is_empty():
		return {"success": false, "reason": "missing_sub"}

	# Step 2: Check revocation in Postgres
	if _is_token_revoked(token):
		return {"success": false, "reason": "revoked"}

	var cid: int = payload.get("cid", 0)
	return {"success": true, "username": username, "cid": cid}


static func revoke_session(token: String) -> bool:
	"""Revoke a session token by storing it in Postgres revocation list."""
	var db := _get_db()
	if db == null:
		return false

	# T-074: revoke BOTH stores in one transaction. session_tokens gates validate_session,
	# but refresh rotation checks auth.sessions.revoked (which nothing ever set) — a
	# "revoked" user kept rotating refresh tokens into fresh access tokens for 24 h.
	var sql := (
		"BEGIN;\n"
		+ "INSERT INTO auth.session_tokens (token, revoked, revoked_at) "
		+ "VALUES ($1, true, NOW()) ON CONFLICT (token) DO UPDATE SET revoked = true, revoked_at = NOW();\n"
		+ "UPDATE auth.sessions SET revoked = true WHERE token = $1;\n"
		+ "COMMIT;"
	)
	var err: int = db.execute_query(sql, [token])
	if err != OK:
		printerr("[session_manager] failed to revoke token: %d" % err)
		return false

	db.close_db()
	return true


static func _is_token_revoked(token: String) -> bool:
	"""Check if a token has been revoked in Postgres."""
	if _test_skip_db:
		return false

	var db := _get_db()
	if db == null:
		# Degraded mode: if DB unavailable, reject (fail-closed)
		return true

	var sql := "SELECT revoked FROM auth.session_tokens WHERE token = $1"
	var err: int = db.execute_query(sql, [token])
	if err != OK:
		# Can't check — fail closed
		printerr("[session_manager] revocation check failed: %d" % err)
		return true

	var result: Variant = db.query_result()
	var rows: Array = result if result is Array else []
	if rows.is_empty():
		# Token not in revocation list — it's fine
		db.close_db()
		return false

	var first_row: Dictionary = rows[0]
	var raw_revoked: Variant = first_row.get("revoked", false)
	# psql -A returns booleans as strings "t"/"f". Convert explicitly.
	var revoked: bool = str(raw_revoked) == "t"
	db.close_db()
	return revoked


static func _get_db() -> Database:
	"""Create and connect to Postgres. Returns null on failure."""
	var db := _create_db()
	if db == null:
		return null
	var err: int = (
		db
		. open_db(
			(
				"host={h} port={p} dbname={d} user={u} password={pw}"
				. format(
					{
						"h": DB_HOST,
						"p": DB_PORT,
						"d": DB_NAME,
						"u": DB_USER,
						"pw": DB_PASS,
					}
				)
			)
		)
	)
	if err != OK:
		printerr("[session_manager] failed to connect to Postgres (err=%d)" % err)
		return null
	return db


static func _create_db() -> Database:
	"""Instantiate the DB plugin (class_name Database).

	T-757: the return is statically typed via the addon's class_name (the addon is
	sync-guaranteed in every project that carries this file — see
	scripts/check_shared_files_sync.sh); load() stays so a broken addon script
	still degrades to null at runtime instead of failing this file's parse.
	"""
	var database_script: GDScript = load("res://addons/database/database.gd")
	return database_script.new() if database_script != null else null


static func set_test_secret(secret: String) -> void:
	"""Set JWT secret for testing purposes."""
	_jwt_secret = secret
	var jwt_util := JwtUtil.new()
	_secret_validated = jwt_util.validate_secret(secret)


static func set_test_refresh_secret(secret: String) -> void:
	"""T-007: Set refresh token secret for testing purposes."""
	_refresh_secret = secret
	var jwt_util := JwtUtil.new()
	_refresh_secret_validated = jwt_util.validate_secret(secret)


static func reset_for_test() -> void:
	"""Reset state for testing."""
	_jwt_secret = ""
	_secret_validated = false
	_test_skip_db = true
	_refresh_secret = ""
	_refresh_secret_validated = false
	_test_refresh_store.clear()
