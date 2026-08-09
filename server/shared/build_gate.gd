extends RefCounted

# T-514: server-authoritative client build gate. Rejects clients on an OLDER build than the minimum
# the operator requires so honest players stay on the latest download (stale builds drift from the
# server's protocol/assets). Enforced at BOTH the gateway login and the world session handshake.
# Canonical copy lives in server/shared/; gateway + world copies are kept byte-identical by the
# pre-push shared-files sync gate (scripts/check_shared_files_sync.sh).
#
# SECURITY — this is a COMPATIBILITY gate, NOT a security boundary. The build stamp is self-reported
# by the client and therefore spoofable; a determined attacker can claim any build. That is fine:
# the goal is keeping cooperative players current, nothing security-sensitive depends on the value,
# and a spoofer just runs an old client (which drifts on its own). What IS hardened is the handling
# of the untrusted string — strict length + anchored-format validation, no interpolation into SQL /
# shell / format strings anywhere, and fail-closed rejection of anything malformed. The check never
# crashes on bad input and rejects cheaply (before any token/DB work), so it adds no DoS surface.

# Build stamps are ISO-8601 UTC instants: "YYYY-MM-DDThh:mm:ssZ". Monotonic, lexically sortable
# (string compare == chronological compare), human-readable, and distinguish same-day rebuilds.
const MAX_BUILD_LEN := 20
const _BUILD_PATTERN := "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"

# The reason string sent to the client and matched by the client to show the "please update" copy.
const REJECT_REASON := "outdated_build"


# Untrusted-input validator: bound length first (cheap), then a fully-anchored format check. No
# other layer ever trusts this string; malformed input returns false rather than raising.
static func is_valid_build(build: String) -> bool:
	if build.length() == 0 or build.length() > MAX_BUILD_LEN:
		return false
	var re := RegEx.new()
	if re.compile(_BUILD_PATTERN) != OK:
		return false
	return re.search(build) != null


# The gate is OPT-IN: it only enforces when the operator sets a VALID minimum build. Unset / blank /
# malformed minimum => disabled, so dev, local, and harness stacks are unaffected.
static func gate_enabled(min_build: String) -> bool:
	return is_valid_build(min_build)


# True when the client is ALLOWED in. Gate off => always allow. Gate on => a missing/garbage client
# build is treated as outdated (fail closed); otherwise the ISO stamps are compared chronologically
# via a plain string compare.
static func meets_minimum(client_build: String, min_build: String) -> bool:
	if not gate_enabled(min_build):
		return true
	if not is_valid_build(client_build):
		return false
	return client_build >= min_build
