class_name OnboardingPrefs
# T-376: per-user memory of onboarding affordances shown, so a returning player is never nagged.
# The "controls card seen" flag is stored under user://onboarding.cfg keyed by USERNAME (not a
# global flag) — two accounts on one machine each get their own first-run. FileAccess I/O is kept
# in the thin load/save helpers; the show/don't-show DECISION is a pure static function so it is
# unit-testable headless (mirrors the settings_panel _loading discipline: logic apart from I/O).

extends RefCounted

const CONFIG_PATH := "user://onboarding.cfg"
const _SECTION := "seen"
const _SETTINGS_SECTION := "settings"
const _CONTROLS_KEY := "controls_card"
const _HINTS_ENABLED_KEY := "hints_enabled"


# Pure decision: given whether this user has already seen the card, should we auto-show it on
# world entry? Only on the very first entry. The help key can always re-open it regardless.
static func should_autoshow_controls(already_seen: bool) -> bool:
	return not already_seen


# T-426 pure decision: fire a contextual hint iff the user has hints on AND this one never fired.
# Fire-once is per hint id per user; "hide hints" (the suppression setting) trumps everything.
static func should_show_hint(already_seen: bool, hints_enabled: bool) -> bool:
	return hints_enabled and not already_seen


# T-550: fire-once is now ACCOUNT-authoritative (the server-fed hints_seen set) with the per-device
# user://onboarding.cfg as the offline/degraded fallback. Either source having seen the hint counts
# as seen — so an alt (even on a new device) never re-nags a hint the account already saw. Pure so
# the controller's suppression rule is unit-testable headless.
static func combined_seen(account_seen: bool, device_seen: bool) -> bool:
	return account_seen or device_seen


# Normalise a username into a stable config key. Empty (offline / no token) collapses to a shared
# "guest" bucket so the flag still persists within a session and across relaunches.
static func user_key(username: String) -> String:
	var u := username.strip_edges().to_lower()
	return u if u != "" else "guest"


# Decode the identity from a session token for the per-user onboarding key. For UI persistence
# only — no signature check; the server already authenticated the session on handshake.
# T-507: prefer the `cname` (selected character) claim so each alt gets its own onboarding
# state and per-character look seed; account-scoped tokens fall back to `sub` (username).
static func username_from_token(token: String) -> String:
	var parts := token.split(".")
	if parts.size() != 3:
		return ""
	var payload := Marshalls.base64_to_utf8(_b64url_pad(parts[1]))
	var json = JSON.parse_string(payload)
	if not (json is Dictionary):
		return ""
	var cname := str(json.get("cname", ""))
	return cname if cname != "" else str(json.get("sub", ""))


static func _b64url_pad(s: String) -> String:
	var t := s.replace("-", "+").replace("_", "/")
	while t.length() % 4 != 0:
		t += "="
	return t


# ---- thin FileAccess helpers (untested; the decision above is what carries the logic) ----


static func has_seen_controls(username: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return false
	return bool(cfg.get_value(_SECTION, _key(username, _CONTROLS_KEY), false))


static func mark_controls_seen(username: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)  # missing file is fine — we create it on save
	cfg.set_value(_SECTION, _key(username, _CONTROLS_KEY), true)
	cfg.save(CONFIG_PATH)


# T-426: has this one contextual hint already fired for this user?
static func has_seen_hint(username: String, hint_id: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return false
	return bool(cfg.get_value(_SECTION, _key(username, "hint_" + hint_id), false))


static func mark_hint_seen(username: String, hint_id: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)  # missing file is fine — we create it on save
	cfg.set_value(_SECTION, _key(username, "hint_" + hint_id), true)
	cfg.save(CONFIG_PATH)


# T-426: the "hide hints" suppression setting (per user; default ON — a new player wants hints).
static func hints_enabled(username: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return true
	return bool(cfg.get_value(_SETTINGS_SECTION, _key(username, _HINTS_ENABLED_KEY), true))


static func set_hints_enabled(username: String, enabled: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value(_SETTINGS_SECTION, _key(username, _HINTS_ENABLED_KEY), enabled)
	cfg.save(CONFIG_PATH)


static func _key(username: String, what: String) -> String:
	return "%s/%s" % [user_key(username), what]
