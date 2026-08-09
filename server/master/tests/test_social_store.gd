extends GutTest

# T-361 item 2: persisted friends/ignore lists — target resolution, self/unknown rejection,
# list caps, and the one-directional semantics the chat filter depends on.

const CharacterManager = preload("res://scripts/character_manager.gd")
const _SS = preload("res://scripts/social_store.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()


func _mk(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func test_add_and_remove_friend_roundtrip() -> void:
	var a := _mk("alice")
	_mk("bob")
	var r := _SS.op({"username": "alice", "action": "add_friend", "target_name": "bob"})
	assert_eq(r["friends"], ["bob"], "mutations return the fresh lists")
	assert_eq(_SS.names(a, "friend"), ["bob"])
	r = _SS.op({"username": "alice", "action": "remove_friend", "target_name": "bob"})
	assert_eq(r["friends"], [], "removed")


func test_ignore_list_is_separate_and_one_directional() -> void:
	var a := _mk("alice")
	var b := _mk("bob")
	_SS.op({"username": "alice", "action": "add_ignore", "target_name": "bob"})
	assert_eq(_SS.names(a, "ignore"), ["bob"])
	assert_eq(_SS.names(a, "friend"), [], "kinds do not bleed")
	assert_eq(_SS.names(b, "ignore"), [], "ignoring is one-directional")


func test_unknown_actor_target_and_self_rejected() -> void:
	_mk("alice")
	var r := _SS.op({"username": "ghost", "action": "add_friend", "target_name": "alice"})
	assert_eq(str(r.get("error", "")), "unknown_character")
	r = _SS.op({"username": "alice", "action": "add_friend", "target_name": "ghost"})
	assert_eq(str(r.get("error", "")), "unknown_target", "target must be a real character")
	r = _SS.op({"username": "alice", "action": "add_friend", "target_name": "alice"})
	assert_eq(str(r.get("error", "")), "self_target")
	r = _SS.op({"username": "alice", "action": "befriend_forever", "target_name": "alice"})
	assert_eq(str(r.get("error", "")), "unknown_action")


func test_duplicate_add_is_idempotent_and_cap_enforced() -> void:
	var a := _mk("alice")
	_mk("bob")
	_SS.op({"username": "alice", "action": "add_friend", "target_name": "bob"})
	_SS.op({"username": "alice", "action": "add_friend", "target_name": "bob"})
	assert_eq(_SS.names(a, "friend").size(), 1, "duplicate add is a no-op")
	for i in range(_SS.MAX_LIST - 1):
		_mk("f%d" % i)
		_SS.op({"username": "alice", "action": "add_friend", "target_name": "f%d" % i})
	_mk("overflow")
	var r := _SS.op({"username": "alice", "action": "add_friend", "target_name": "overflow"})
	assert_eq(str(r.get("error", "")), "list_full", "cap bounds the list")


func test_list_action_returns_both_lists() -> void:
	_mk("alice")
	_mk("bob")
	_mk("troll")
	_SS.op({"username": "alice", "action": "add_friend", "target_name": "bob"})
	_SS.op({"username": "alice", "action": "add_ignore", "target_name": "troll"})
	var r := _SS.op({"username": "alice", "action": "list"})
	assert_eq(r["friends"], ["bob"])
	assert_eq(r["ignored"], ["troll"])


# T-451: the help channel is opt-in by default for a newly-created character, with a persisted
# preference toggle. This is a preference only; it grants no gameplay state.
func test_new_character_defaults_to_help_and_can_opt_out() -> void:
	var alice := _mk("alice")
	assert_true(_SS.help_subscribed(alice), "new characters default into help")
	var r := _SS.op({"username": "alice", "action": "set_help", "subscribed": false})
	assert_false(bool(r.get("help_subscribed", true)), "opt-out is reflected in the reply")
	assert_false(_SS.help_subscribed(alice), "opt-out persists in the store")
	r = _SS.op({"username": "alice", "action": "set_help", "subscribed": true})
	assert_true(bool(r.get("help_subscribed", false)), "players can opt back in")
