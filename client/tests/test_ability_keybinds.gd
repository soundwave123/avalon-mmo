extends GutTest

# T-723: the keyboard could only cast action-bar slots 1-4 while the bar drew nine slots with 1-9
# pips — so the role-free interrupts (Pummel/Counterspell, which land past slot 4 on a trained
# kit's default layout) were unreachable without a mouse. These tests hold the whole chain:
#
#   1. the MAP itself (AbilityKeybinds: slot <-> keycode, both directions, and the non-keys)
#   2. DISPATCH through the REAL main.gd._input path — a forged KEY_5..KEY_9 must reach the wire
#      with the right ability id, via the same _cast_kit_slot / AbilityCastQueue arbitration
#      keys 1-4 use (the T-721 press ledger must see every press, not just the old four)
#   3. the DISPLAY surfaces that promise the binding: the bar's keybind pips + tooltips, the F1
#      handbook row/glossary, and the Esc > Controls list (T-078)

const MainScene = preload("res://scripts/main.gd")
const ActionBarScene = preload("res://scripts/ui/action_bar.gd")
const PlayerHudScene = preload("res://scripts/ui/player_hud.gd")
const SettingsPanelScene = preload("res://scripts/ui/settings_panel.gd")


# Records what left the client for the server (main._net is untyped, so a spy drops straight in).
class NetSpy:
	extends RefCounted
	var used: Array = []

	func request_use_ability(ability_id: int, target_id: int) -> void:
		used.append([ability_id, target_id])


var _main = null
var _spy: NetSpy = null


# A full nine-ability kit with ids that make the slot obvious: slot i holds ability 500 + i.
func _kit(n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({"id": 500 + i, "name": "Ability %d" % i})
	return out


# Main wired only where _input touches: a real PlayerHud (the bar owns slot -> ability id), a net
# spy, a live target and a built world. Never added to the tree, so the scene-dependent _ready
# never runs — the same seam test_main_input_gate.gd uses.
func _live_main(slots: int) -> void:
	_main = MainScene.new()
	var hud = PlayerHudScene.new()
	add_child_autofree(hud)
	var kit := _kit(slots)
	hud.set_kit(kit)
	_spy = NetSpy.new()
	_main.player_hud = hud
	_main._kit = kit
	_main._target_id = 7
	_main._net = _spy
	_main._world_built = true


func after_each() -> void:
	if _main != null:
		# Main builds two helper Nodes at declaration (the T-721 cast queue, the onboarding
		# controller) and only parents them in _ready — which never ran here, so free them by hand
		# instead of leaving orphans behind for the next script in the run.
		_main._cast_queue.free()
		_main._onboarding.free()
		_main.free()
		_main = null


func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	return ev


# ---- 1. the map ---------------------------------------------------------------


func test_every_slot_has_a_key_and_every_key_a_slot() -> void:
	for slot in range(AbilityKeybinds.SLOT_COUNT):
		var keycode: int = AbilityKeybinds.keycode_for_slot(slot)
		assert_ne(keycode, -1, "slot %d must bind a key" % slot)
		assert_eq(AbilityKeybinds.slot_for_keycode(keycode), slot, "round trip for slot %d" % slot)


func test_non_ability_keys_map_to_no_slot() -> void:
	# Every other hotkey main._input owns must fall through the ability branch untouched.
	for keycode in [KEY_0, KEY_L, KEY_I, KEY_N, KEY_C, KEY_M, KEY_TAB, KEY_QUOTELEFT, KEY_ESCAPE]:
		assert_eq(
			AbilityKeybinds.slot_for_keycode(keycode),
			-1,
			"%s is not an ability key" % OS.get_keycode_string(keycode)
		)


func test_keyed_range_covers_the_whole_bar() -> void:
	# The T-723 bug in one assert: a keyed range SHORTER than the drawn bar leaves rendered slots
	# (and the interrupts sitting in them) uncastable. A LONGER one advertises keys for nothing.
	assert_eq(
		AbilityKeybinds.SLOT_COUNT,
		ActionBarScene.MAX_SLOTS,
		"the keyboard must reach exactly the slots the bar draws"
	)


# ---- 2. dispatch through the real input path ----------------------------------


func test_keys_five_through_nine_cast_their_slots() -> void:
	_live_main(AbilityKeybinds.SLOT_COUNT)
	for slot in range(4, AbilityKeybinds.SLOT_COUNT):  # the range that used to be dead
		_main._input(_key(AbilityKeybinds.keycode_for_slot(slot)))
	assert_eq(_spy.used.size(), AbilityKeybinds.SLOT_COUNT - 4, "every key past 4 reached the wire")
	for i in range(_spy.used.size()):
		assert_eq(
			_spy.used[i], [500 + 4 + i, 7], "key %d cast its own slot at the target" % (5 + i)
		)


func test_first_four_keys_still_cast_their_slots() -> void:
	_live_main(AbilityKeybinds.SLOT_COUNT)
	for slot in range(4):
		_main._input(_key(AbilityKeybinds.keycode_for_slot(slot)))
	assert_eq(_spy.used, [[500, 7], [501, 7], [502, 7], [503, 7]], "1-4 unchanged (T-063)")


func test_new_keys_go_through_the_same_cast_queue() -> void:
	# T-721 arbitration is the ONLY dispatch path: a key-5 press must be recorded in the press
	# ledger exactly like a key-1 press, or its on_gcd refusal would never be re-sent.
	_live_main(AbilityKeybinds.SLOT_COUNT)
	_main._input(_key(AbilityKeybinds.keycode_for_slot(6)))  # key 7
	var counts: Dictionary = _main._cast_queue.summary()["counts"]
	assert_eq(int(counts.get("send:506", 0)), 1, "the press ledger saw the slot-7 send")
	assert_eq(int(_main._cast_queue._pending.get("ability_id", -1)), 506, "queued for a retry")


func test_a_key_past_the_kit_dispatches_nothing() -> void:
	# A four-ability kit leaves keys 5-9 pointing at empty slots: no wire traffic, and the ledger
	# records WHY rather than dropping the press on the floor.
	_live_main(4)
	_main._input(_key(AbilityKeybinds.keycode_for_slot(7)))  # key 8, no such slot
	assert_eq(_spy.used.size(), 0, "an empty slot sends nothing")
	var counts: Dictionary = _main._cast_queue.summary()["counts"]
	assert_eq(int(counts.get("blocked:no_kit_slot:-1", 0)), 1, "the ledger names the block")


func test_class_panel_still_swallows_the_ability_keys() -> void:
	# T-065: during class selection the number row belongs to the panel. Widening the range must
	# not open a hole in that gate.
	_live_main(AbilityKeybinds.SLOT_COUNT)
	var panel := ClassPanel.new()
	add_child_autofree(panel)
	panel.visible = true
	_main.class_panel = panel
	_main._input(_key(AbilityKeybinds.keycode_for_slot(5)))
	assert_eq(_spy.used.size(), 0, "no casting while the class panel is up")


# ---- 3. the surfaces that promise the binding ---------------------------------


func test_bar_pips_and_tooltips_print_the_real_keys() -> void:
	var bar := ActionBarScene.new()
	add_child_autofree(bar)
	bar.set_kit(_kit(AbilityKeybinds.SLOT_COUNT))
	for slot in range(AbilityKeybinds.SLOT_COUNT):
		var key_label := AbilityKeybinds.slot_label(slot)
		assert_eq(bar.hotkey_label(slot), key_label, "slot %d pip prints its key" % slot)
		assert_string_contains(bar.slot_tooltip_text(slot), key_label)


func test_handbook_row_advertises_the_widened_range() -> void:
	var label := ""
	for row: Dictionary in ControlsReference.rows():
		if str(row["action"]) == "Abilities":
			label = str(row["keys_label"])
	assert_string_contains(label, AbilityKeybinds.slot_label(AbilityKeybinds.SLOT_COUNT - 1))
	var tip := ""
	for row: Dictionary in ControlsReference.glossary_rows():
		if str(row["term"]) == "Abilities":
			tip = str(row["tip"])
	assert_string_contains(tip, AbilityKeybinds.range_label())
	assert_false(tip.contains("{keys}"), "the glossary token is resolved, not printed raw")


func test_options_controls_list_shows_the_live_range() -> void:
	# T-078's Controls display is where a player looks the binding up — it used to read "1 - 4".
	var panel = SettingsPanelScene.new()
	var row_keys := ""
	for row: Array in panel._keybind_rows():
		if str(row[0]) == "Action bar":
			row_keys = str(row[1])
	panel.free()
	assert_eq(row_keys, AbilityKeybinds.range_label(), "Options lists the live ability-key range")
