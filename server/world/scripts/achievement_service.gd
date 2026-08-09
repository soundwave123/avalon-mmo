extends RefCounted

# T-367: world-side achievement seam. Two jobs, both thin trust-boundary relays — the MASTER owns
# all achievement state (progress, earned set, reward grants):
#   1. the client's READ-ONLY panel request (achievement_list) → master achievement_op "list",
#   2. forwarding server-observed EARN events (folded into credit_kill/turn_in/credit_reach results
#      by the master) to the earner as a toast.
# There is NO client verb that grants an achievement — earns are server-observed only, so a cheat
# client can neither assert an achievement nor a reward (test_adversarial_client asserts this).
# RefCounted; world_rpc owns an instance and injects master + the reply Callable (like _reply).

const PlayerSessions = preload("res://scripts/player_sessions.gd")

const READ_INTENT := "achievement_list"
const RENOWN_INTENT := "renown_list"  # T-678: same trust boundary — read-only standing feed

var _master = null  # MasterClient (call_master)
var _reply: Callable  # world_rpc._reply → main._send_to_peer(peer_id, dict)


func setup(master, reply: Callable) -> void:
	_master = master
	_reply = reply


func handles(msg_type: String) -> bool:
	return msg_type == READ_INTENT or msg_type == RENOWN_INTENT


# Client asked to see its achievements. Identity is the session's — never the wire's.
func handle_read(peer_id: int, player: Dictionary) -> void:
	if _master == null:
		return
	var result: Dictionary = await _master.call_master(
		"achievement_op", {"username": str(player.get("username", "")), "action": "list"}
	)
	_reply.call(
		peer_id, {"type": "achievement_list", "achievements": result.get("achievements", [])}
	)


# T-678: the renown panel feed — identical trust shape to handle_read (master owns all standing;
# grants are server-observed inside the master's turn-in path, never a client verb).
func handle_renown_read(peer_id: int, player: Dictionary) -> void:
	if _master == null:
		return
	var result: Dictionary = await _master.call_master(
		"renown_op", {"username": str(player.get("username", "")), "action": "list"}
	)
	_reply.call(peer_id, {"type": "renown_list", "renown": result.get("renown", [])})


# Fold a credit result's newly-earned achievements out to the earner as a toast. No-op when none.
func forward(peer_id: int, result: Dictionary) -> void:
	var earned: Array = result.get("achievements", [])
	if not earned.is_empty():
		_reply.call(peer_id, {"type": "achievements_earned", "earned": earned})
