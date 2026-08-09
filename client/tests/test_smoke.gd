extends "res://addons/gut/test.gd"

# Smoke test for the Avalon client.
# Asserts that the main scene packs and instantiates.
# This pins the Phase B contract: client/scenes/main.tscn must
# remain instantiable headlessly.

const MAIN_SCENE_PATH := "res://scenes/main.tscn"


func test_main_scene_loads_as_packedscene() -> void:
	var packed := load(MAIN_SCENE_PATH)
	assert_not_null(packed, "main.tscn must load")
	assert_true(packed is PackedScene, "main.tscn must be a PackedScene")


func test_main_scene_root_is_a_node() -> void:
	var packed: PackedScene = load(MAIN_SCENE_PATH)
	var inst := packed.instantiate()
	assert_not_null(inst, "main.tscn must instantiate")
	assert_true(inst is Node, "main.tscn root must be a Node")
	inst.queue_free()
