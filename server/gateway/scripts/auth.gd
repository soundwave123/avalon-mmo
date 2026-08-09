extends RefCounted

# Gateway auth/session module.
#
# JWT-based authentication (T-006). Signs HS256 tokens on successful login.
# Two-token model (T-007): access tokens (15 min) + refresh tokens (24h).
# Refresh tokens are single-use with atomic rotation in Postgres.
# Uses JwtUtil for signing and validation.
#
# FAIL-FAST: Validates both JWT signing secrets on first use. If either is
# missing or too short (< 32 bytes), throws FATAL error and gateway won't start.

const JwtUtil = preload("res://scripts/jwt.gd")
const SessionManager = preload("res://scripts/session_manager.gd")
const PasswordHash = preload("res://scripts/password_hash.gd")

# T-074: username charset allowlist. The username is the ONLY user-controlled string that
# reaches jwt.gd's hand-rolled JSON, database.gd's TSV parsing, and _string_to_bytes —
# quotes, tabs, and non-ASCII each corrupt one of those layers.
const USERNAME_PATTERN := "^[a-z0-9_-]{3,20}$"
const AUTH_MODE_ACCOUNTS := "accounts"
const AUTH_MODE_DEV := "dev"

static var _auth_mode: String = AUTH_MODE_ACCOUNTS
static var _test_accounts_enabled: bool = false
static var _test_accounts: Dictionary = {}

static var _jwt_secret: String = ""
static var _jwt_ttl: int = 900  # T-007: 15 min access token
static var _secret_validated: bool = false

# T-007: Refresh token configuration
static var _refresh_secret: String = ""
static var _refresh_ttl: int = 86400  # 24 hours
static var _refresh_secret_validated: bool = false


static func init_from_env() -> void:
	"""Read JWT config from environment. Call on startup."""
	var requested_mode := str(OS.get_environment("AVALON_AUTH_MODE")).strip_edges().to_lower()
	if requested_mode == AUTH_MODE_DEV:
		_auth_mode = AUTH_MODE_DEV
	else:
		_auth_mode = AUTH_MODE_ACCOUNTS
		if not requested_mode.is_empty() and requested_mode != AUTH_MODE_ACCOUNTS:
			push_warning("[gateway] unknown AVALON_AUTH_MODE; using accounts mode")
	print("[gateway] auth_mode=%s" % _auth_mode)

	var secret := OS.get_environment("AVALON_JWT_SECRET")
	if secret != null and not str(secret).is_empty():
		_jwt_secret = str(secret)
	else:
		_jwt_secret = ""

	var ttl := OS.get_environment("AVALON_JWT_TTL_SECONDS")
	if ttl != null and not str(ttl).is_empty():
		_jwt_ttl = int(str(ttl))

	# T-007: Read refresh token config
	var refresh_secret := OS.get_environment("AVALON_JWT_REFRESH_SECRET")
	if refresh_secret != null and not str(refresh_secret).is_empty():
		_refresh_secret = str(refresh_secret)
	else:
		_refresh_secret = ""

	var refresh_ttl := OS.get_environment("AVALON_JWT_REFRESH_TTL_SECONDS")
	if refresh_ttl != null and not str(refresh_ttl).is_empty():
		_refresh_ttl = int(str(refresh_ttl))

	# FAIL-FAST: Validate both secrets
	_validate_secret_guard()
	_validate_refresh_secret_guard()


static func _validate_secret_guard() -> void:
	"""
	Validate JWT signing secret meets minimum requirements.
	If invalid, prints FATAL and returns false — caller must abort startup.
	"""
	if _secret_validated:
		return

	var jwt_util = JwtUtil.new()
	if not jwt_util.validate_secret(_jwt_secret):
		push_warning(
			(
				"[gateway] FATAL: AVALON_JWT_SECRET missing or too short (< 32 bytes). "
				+ "Refusing to start."
			)
		)
		# Signal caller to abort
		return

	_secret_validated = true
	var secret_bytes: int = _jwt_secret.length()
	print("[gateway] jwt_secret loaded: %d bytes" % secret_bytes)


static func _validate_refresh_secret_guard() -> void:
	"""
	T-007: Validate refresh token signing secret meets minimum requirements.
	If invalid, prints FATAL and returns — caller must abort startup.
	"""
	if _refresh_secret_validated:
		return

	var jwt_util = JwtUtil.new()
	if not jwt_util.validate_secret(_refresh_secret):
		push_warning(
			(
				"[gateway] FATAL: AVALON_JWT_REFRESH_SECRET missing or too short (< 32 bytes). "
				+ "Refusing to start."
			)
		)
		return

	_refresh_secret_validated = true
	var secret_bytes: int = _refresh_secret.length()
	print("[gateway] jwt_refresh_secret loaded: %d bytes" % secret_bytes)


static func is_secret_valid() -> bool:
	"""Check if BOTH JWT secrets pass validation. Returns false if either is missing/short."""
	var jwt_util = JwtUtil.new()
	var access_ok = jwt_util.validate_secret(_jwt_secret)
	var refresh_ok = jwt_util.validate_secret(_refresh_secret)
	return access_ok and refresh_ok


static func valid_username(username: String) -> bool:
	var re := RegEx.new()
	re.compile(USERNAME_PATTERN)
	return re.search(username) != null


static func validate_login(username: String, password: String) -> bool:
	"""Validate dev credentials or an owner-provisioned active account. Always fail closed."""
	if not valid_username(username):
		return false
	if _auth_mode == AUTH_MODE_DEV:
		return password == "dev"
	var account := _lookup_account(username)
	if account.is_empty() or str(account.get("username", "")) != username:
		return false
	if not _db_bool(account.get("is_active", false)):
		return false
	return PasswordHash.verify(password, str(account.get("password_hash", "")))


static func _lookup_account(username: String) -> Dictionary:
	if _test_accounts_enabled:
		return (_test_accounts.get(username, {}) as Dictionary).duplicate()
	var Database := load("res://addons/database/database.gd")
	if Database == null:
		return {}
	var db: Object = Database.new()
	if db.open_db("") != OK:
		return {}
	var sql := (
		"SELECT username, password_hash, is_active FROM auth.accounts "
		+ "WHERE username = $1 LIMIT 1"
	)
	if db.execute_query(sql, [username]) != OK:
		db.close_db()
		return {}
	var rows: Variant = db.query_result()
	db.close_db()
	if rows == null or rows.is_empty():
		return {}
	return (rows[0] as Dictionary).duplicate()


static func _db_bool(value: Variant) -> bool:
	if value is bool:
		return value
	return str(value).to_lower() in ["t", "true", "1"]


static func issue_token(username: String) -> String:
	"""
	Issue a signed JWT access token for the given username.
	Returns empty string if secret validation fails.
	T-007: Use issue_tokens() for login flow (access + refresh).
	"""
	if not _secret_validated:
		_validate_secret_guard()
		if not _secret_validated:
			return ""

	var jwt_util = JwtUtil.new()
	var token: String = jwt_util.sign({"sub": username}, _jwt_secret, _jwt_ttl, "access")
	return token


static func issue_tokens(
	username: String, character_id: int = 0, character_name: String = ""
) -> Dictionary:
	"""
	T-007: Issue both access and refresh tokens for login.
	T-507: character_id/character_name > 0/"" stamp the SELECTED character into both tokens
	(cid/cname claims) — only ever called after an ownership check against the roster, and
	the master RE-validates the claim at validate_session. Without a claim, the master
	auto-resolves (0 chars -> bootstrap, 1 char -> that one, 2+ -> selection required).
	Returns {access_token: String, refresh_token: String} on success,
	or {error: String} on failure.
	"""
	if not _secret_validated or not _refresh_secret_validated:
		_validate_secret_guard()
		_validate_refresh_secret_guard()
		if not _secret_validated or not _refresh_secret_validated:
			return {"error": "secret_validation_failed"}

	var jwt_util = JwtUtil.new()

	# Generate unique JTI for this refresh token
	var jti: String = JwtUtil.generate_jti()

	var access_claims: Dictionary = {"sub": username}
	var refresh_claims: Dictionary = {"sub": username, "jti": jti}
	if character_id > 0 and character_name != "":
		access_claims["cid"] = character_id
		access_claims["cname"] = character_name
		refresh_claims["cid"] = character_id
		refresh_claims["cname"] = character_name

	# Issue access token (15 min)
	var access_token: String = jwt_util.sign(access_claims, _jwt_secret, _jwt_ttl, "access")

	# Issue refresh token (24h) with jti
	var refresh_token: String = jwt_util.sign(
		refresh_claims, _refresh_secret, _refresh_ttl, "refresh"
	)

	# Store session in master with refresh_token_id
	SessionManager.store_refresh_session(username, jti, access_token, refresh_token)

	return {
		"access_token": access_token,
		"refresh_token": refresh_token,
	}


static func rotate_refresh_token(refresh_token: String) -> Dictionary:
	"""
	T-007: Rotate a single-use refresh token.

	Presented refresh token must be valid, unexpired, type="refresh",
	and its jti must match the current refresh_token_id for that session.
	Atomic DB update ensures only ONE concurrent rotation succeeds.

	Returns:
		{success: true, access_token: ..., refresh_token: ...} on success
		{success: false, reason: String} on failure (401)
	"""
	if not _secret_validated or not _refresh_secret_validated:
		_validate_secret_guard()
		_validate_refresh_secret_guard()
		if not _secret_validated or not _refresh_secret_validated:
			return {"success": false, "reason": "secret_validation_failed"}

	var jwt_util = JwtUtil.new()

	# Verify refresh token signature + expiry + type
	var result: Dictionary = jwt_util.verify_type(refresh_token, _refresh_secret, "refresh")
	if not result.get("valid", false):
		return {"success": false, "reason": result.get("reason", "invalid_token")}

	var payload: Dictionary = result["payload"]
	var username: String = str(payload.get("sub", ""))
	var old_jti: String = str(payload.get("jti", ""))

	if username.is_empty() or old_jti.is_empty():
		return {"success": false, "reason": "missing_claims"}

	# Atomic rotation: update refresh_token_id in DB
	# Only succeeds if old_jti matches AND session not revoked
	var rotation_result: Dictionary = SessionManager.rotate_refresh(username, old_jti)

	if not rotation_result.get("success", false):
		# Replayed, expired, or revoked — HARD REJECTION (401)
		return {
			"success": false,
			"reason": rotation_result.get("reason", "refresh_token_consumed"),
		}

	# Rotation succeeded — issue new token pair
	var new_jti: String = JwtUtil.generate_jti()

	# T-507: the selected character rides rotation — the verified OLD refresh token's cid/cname
	# carry into the new pair, so a mid-session refresh never silently drops the selection.
	var new_access_claims: Dictionary = {"sub": username}
	var new_refresh_claims: Dictionary = {"sub": username, "jti": new_jti}
	if int(payload.get("cid", 0)) > 0 and str(payload.get("cname", "")) != "":
		new_access_claims["cid"] = int(payload["cid"])
		new_access_claims["cname"] = str(payload["cname"])
		new_refresh_claims["cid"] = int(payload["cid"])
		new_refresh_claims["cname"] = str(payload["cname"])

	var new_access: String = jwt_util.sign(new_access_claims, _jwt_secret, _jwt_ttl, "access")
	var new_refresh: String = jwt_util.sign(
		new_refresh_claims, _refresh_secret, _refresh_ttl, "refresh"
	)

	# Store new refresh session
	SessionManager.store_refresh_session(username, new_jti, new_access, new_refresh)

	return {
		"success": true,
		"access_token": new_access,
		"refresh_token": new_refresh,
	}


static func verify_token(token: String) -> Dictionary:
	"""
	Verify a JWT token and return the payload if valid.
	Returns {"valid": false, "reason": String} on failure.
	"""
	var jwt_util = JwtUtil.new()
	var result: Dictionary = jwt_util.verify(token, _jwt_secret)
	return result


# ---- Test helpers ----


static func set_test_secret(secret: String) -> void:
	"""Set JWT secret for testing purposes."""
	_jwt_secret = secret
	var jwt_util = JwtUtil.new()
	_secret_validated = jwt_util.validate_secret(secret)


static func set_test_refresh_secret(secret: String) -> void:
	"""T-007: Set refresh token secret for testing purposes."""
	_refresh_secret = secret
	var jwt_util = JwtUtil.new()
	_refresh_secret_validated = jwt_util.validate_secret(secret)


static func reset_for_test() -> void:
	"""Reset state for testing."""
	_jwt_secret = ""
	_jwt_ttl = 900
	_secret_validated = false
	_refresh_secret = ""
	_refresh_ttl = 86400
	_refresh_secret_validated = false
	_auth_mode = AUTH_MODE_ACCOUNTS
	_test_accounts_enabled = true
	_test_accounts.clear()
	SessionManager.reset_for_test()


static func set_test_auth_mode(mode: String) -> void:
	_auth_mode = AUTH_MODE_DEV if mode == AUTH_MODE_DEV else AUTH_MODE_ACCOUNTS


static func set_test_account(username: String, password_hash: String, is_active: bool) -> void:
	_test_accounts_enabled = true
	_test_accounts[username] = {
		"username": username,
		"password_hash": password_hash,
		"is_active": is_active,
	}
