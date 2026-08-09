extends GutTest

# T-494: the gateway login form (T-500) must be a real modal gate. Boot builds NEITHER the world nor
# the HUD until authentication succeeds, so while the login form is up there is no standing HUD, no
# `?` affordance, and no hotkey listener behind it. main.gd guards that with `_world_built`: _input
# early-returns until the world is built, so a letter key an unauthenticated player types (C / I /
# R, all bound to HUD panels) reaches the login LineEdits instead of toggling a panel behind it.
#
# This drives the real main._input path with a stand-in for the pre-auth vs post-auth states and
# proves the panel toggles are dead before authentication and live after — the same headless
# forged-keypress idiom as test_main_input_gate.gd.

const MainScene = preload("res://scripts/main.gd")


class NetSpy:
	extends RefCounted
	var inventory_requests := 0

	func get_inventory() -> void:
		inventory_requests += 1


var _m = null
var _character: CharacterSheetPanel = null
var _inventory: InventoryPanel = null
var _spy: NetSpy = null


func before_each() -> void:
	# Build Main WITHOUT adding it to the tree, so its scene-dependent _ready never runs. Wire only
	# the two panels _input toggles (added to the test tree so their own _ready runs -> visible=false)
	# plus a net spy for the inventory-open fetch.
	_m = MainScene.new()
	_character = CharacterSheetPanel.new()
	_inventory = InventoryPanel.new()
	add_child_autofree(_character)
	add_child_autofree(_inventory)
	await get_tree().process_frame
	_spy = NetSpy.new()
	_m.character_sheet_panel = _character
	_m.inventory_panel = _inventory
	_m._net = _spy


func after_each() -> void:
	if _m != null:
		_m.free()
		_m = null


func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	return ev


func test_fresh_main_builds_no_world_or_hud_before_authentication() -> void:
	var fresh = MainScene.new()
	assert_false(fresh._world_built, "the world/HUD is not built until authentication")
	assert_null(fresh.player_hud, "no standing HUD (PlayerHud) exists behind the login form")
	assert_null(fresh.character_sheet_panel, "no HUD panels are mounted behind the login form")
	fresh.free()


func test_hud_hotkeys_are_dead_before_the_world_is_built() -> void:
	assert_false(_m._world_built, "pre-auth: the world is not built")
	_m._input(_key(KEY_C))  # would open the Character sheet in-world
	_m._input(_key(KEY_I))  # would open Inventory in-world
	assert_false(_character.visible, "C does NOT open the Character sheet behind the login form")
	assert_false(_inventory.visible, "I does NOT open Inventory behind the login form")
	assert_eq(_spy.inventory_requests, 0, "no inventory fetch fires from a login keystroke")


func test_hud_hotkeys_resume_after_the_world_is_built() -> void:
	_m._world_built = true  # authentication succeeded -> _enter_world() ran
	_m._input(_key(KEY_C))
	assert_true(_character.visible, "post-auth: C opens the Character sheet as before")
	_m._input(_key(KEY_I))
	assert_true(_inventory.visible, "post-auth: I opens Inventory as before")
	assert_eq(_spy.inventory_requests, 1, "opening Inventory fetches fresh slots as before")
