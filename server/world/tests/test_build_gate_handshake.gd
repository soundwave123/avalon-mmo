extends "res://addons/gut/test.gd"

# T-514b: the WORLD session handshake enforces the client build gate (defense in depth) so a cached
# token can't let a stale client skip the update by connecting straight to the world. The pure
# BuildGate decision matrix is unit-tested in the gateway; here we prove the WIRING inside
# _on_session_handshake — a stale build is rejected (handshake_err + disconnect) BEFORE any token /
# master work, and a current build passes the gate. The reject path returns before the first await,
# so the coroutine's side effects land synchronously.

const BuildGate = preload("res://scripts/build_gate.gd")

const _MIN := "2026-07-14T00:00:00Z"
const _STALE := "2026-07-01T00:00:00Z"
const _CURRENT := "2026-07-15T00:00:00Z"


# Harness: capture the two outbound side effects the gate uses, and never touch real networking.
class _HarnessMain:
	extends "res://scripts/main.gd"
	var sent: Array = []
	var disconnected: Array = []

	func _send_to_peer(peer_id: int, data: Dictionary) -> void:
		sent.append({"peer_id": peer_id, "data": data})

	func _disconnect_peer(peer_id: int) -> void:
		disconnected.append(peer_id)


func _make(min_build: String) -> _HarnessMain:
	var m := _HarnessMain.new()
	m._min_build = min_build
	return m


func test_world_rejects_stale_build_at_handshake() -> void:
	var m := _make(_MIN)
	m._on_session_handshake(7, {"token": "deadbeef", "build": _STALE})
	assert_eq(m.sent.size(), 1, "one handshake_err sent to the stale peer")
	assert_eq(m.sent[0]["data"]["type"], "handshake_err", "error frame type")
	assert_eq(m.sent[0]["data"]["reason"], BuildGate.REJECT_REASON, "reason == outdated_build")
	assert_eq(m.sent[0]["data"]["required"], _MIN, "required min build echoed back")
	assert_eq(m.disconnected, [7], "stale peer disconnected")
	m.free()


func test_world_rejects_missing_build_when_gate_on() -> void:
	# Fail closed: a client that omits its build stamp is treated as outdated.
	var m := _make(_MIN)
	m._on_session_handshake(9, {"token": "deadbeef"})
	assert_eq(m.sent.size(), 1, "missing build rejected")
	assert_eq(m.sent[0]["data"]["reason"], BuildGate.REJECT_REASON, "reason == outdated_build")
	assert_eq(m.disconnected, [9], "peer disconnected")
	m.free()


func test_world_passes_current_build_past_gate() -> void:
	# A current build clears the gate — no outdated_build frame is emitted. It then falls through to
	# the token-format check (bad token here), which disconnects without a handshake_err payload.
	var m := _make(_MIN)
	m._on_session_handshake(3, {"token": "bad-token", "build": _CURRENT})
	assert_true(m.sent.is_empty(), "no handshake_err — current build cleared the build gate")
	assert_eq(m.disconnected, [3], "disconnected later (invalid token), not by the build gate")
	m.free()


func test_world_gate_off_allows_any_build() -> void:
	# Unset AVALON_MIN_BUILD => gate disabled: even a garbage build clears it (dev/harness stacks).
	var m := _make("")
	m._on_session_handshake(4, {"token": "bad-token", "build": "not-a-date"})
	assert_true(m.sent.is_empty(), "gate off — no outdated_build frame")
	assert_eq(m.disconnected, [4], "disconnected later on the token check, not the build gate")
	m.free()
