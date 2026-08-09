extends GutTest

# T-424: main.gd._input dispatches the hotkeys (autoattack = KEY_QUOTELEFT, ability slots 1-4,
# panel toggles) and is supposed to early-return whenever chat_panel.is_typing() is true, so typing
# in chat never fires combat/UI actions. This drives a real focused ChatPanel through the actual
# main._input path and asserts a forged autoattack / ability keypress is swallowed while typing.
# The WASD/jump half of the same bug lives in local_player.gd and is covered by test_local_player.

const MainScene = preload("res://scripts/main.gd")


# A recording stand-in for ClientNet (main._net is untyped) — proves an ability key never reaches
# the wire while typing.
class NetSpy:
	extends RefCounted
	var ability_calls: Array = []

	func request_use_ability(ability_id: int, target_id: int) -> void:
		ability_calls.append([ability_id, target_id])


var _m = null
var _chat: ChatPanel = null
var _spy: NetSpy = null


func before_each() -> void:
	# Build Main WITHOUT adding it to the tree, so its scene-dependent _ready never runs; wire only
	# the seams _input touches: a real focused ChatPanel, a net spy, a target + kit so the ability
	# path is otherwise live and only the typing gate stops it.
	_m = MainScene.new()
	_chat = ChatPanel.new()
	add_child(_chat)
	await get_tree().process_frame
	_chat.setup(func(_intent): pass)
	_chat._input(_key(KEY_ENTER))  # summon + focus the input row (is_typing() -> true)
	await get_tree().process_frame
	_spy = NetSpy.new()
	_m.chat_panel = _chat
	_m._net = _spy
	_m._target_id = 5
	_m._kit = [0]  # slot 0 is a valid kit index
	_m._world_built = true  # T-494: post-login, the world is built so the hotkey path is live


func after_each() -> void:
	# Release keyboard focus and free everything so no focused input / dangling Main leaks into the
	# next test in the shared tree.
	if _chat != null:
		_chat._input(_key(KEY_ESCAPE))
		_chat.free()
		_chat = null
	if _m != null:
		_m.free()
		_m = null


func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	return ev


func test_autoattack_key_gated_while_typing() -> void:
	assert_true(_chat.is_typing(), "chat input holds focus — is_typing() is true")
	_m._input(_key(KEY_QUOTELEFT))  # ` — the autoattack toggle
	assert_false(_m._autoattack, "backtick does NOT toggle autoattack while typing")


func test_ability_key_gated_while_typing() -> void:
	_m._input(_key(KEY_1))  # ability slot 1
	_m._input(_key(KEY_2))
	assert_eq(_spy.ability_calls.size(), 0, "ability slot keys never reach the net while typing")


# The gate is only as good as the predicate: once focus leaves the input, is_typing() must report
# false so the very same keys are free to act again (the "restored" half of the fix).
func test_predicate_clears_when_focus_leaves_input() -> void:
	assert_true(_chat.is_typing(), "typing while the input is focused")
	_chat._input(_key(KEY_ESCAPE))  # cancel typing — releases focus
	await get_tree().process_frame
	assert_false(_chat.is_typing(), "focus released — hotkeys are live again")


func test_tab_selects_a_server_snapshot_mob() -> void:
	_chat._input(_key(KEY_ESCAPE))
	await get_tree().process_frame
	var remotes := RemoteEntitiesLayer.new()
	add_child_autofree(remotes)
	remotes.ingest(
		{"players": [], "mobs": [{"mob_id": 1001, "x": 3, "y": 0, "z": 0, "hp": 80, "max_hp": 80}]},
		99,
		1000
	)
	_m.remote_entities = remotes
	_m._target_id = -1
	_m._input(_key(KEY_TAB))
	assert_eq(_m._target_id, 1001, "TAB selects an enemy from the replicated server snapshot")


func test_local_player_death_clears_current_target() -> void:
	_chat._input(_key(KEY_ESCAPE))
	await get_tree().process_frame
	var remotes := RemoteEntitiesLayer.new()
	add_child_autofree(remotes)
	remotes.ingest(
		{"players": [], "mobs": [{"mob_id": 1001, "x": 3, "y": 0, "z": 0, "hp": 80, "max_hp": 80}]},
		99,
		1000
	)
	var hud := PlayerHud.new()
	add_child_autofree(hud)
	await get_tree().process_frame
	_m.remote_entities = remotes
	_m.player_hud = hud
	_m.combat_feedback = CombatFeedback.new()
	add_child_autofree(_m.combat_feedback)
	await get_tree().process_frame
	_m._attack_timer = Timer.new()
	_m._my_peer_id = 99
	_m._target_id = 1001
	_m._autoattack = true
	remotes.set_target(1001)
	hud.target_frame.bind_target("Gray Wolf", 80, 80, Color.RED, 1)

	_m._on_combat({"type": "player_death", "peer_id": 99, "target_id": 99})

	assert_eq(_m._target_id, -1, "local death drops the current target")
	assert_false(hud.target_frame.is_bound(), "target frame hides on local death")
