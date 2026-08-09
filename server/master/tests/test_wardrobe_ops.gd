extends GutTest

# T-428: persisted slot-level wardrobe authority. The real inventory remains the sole stat source;
# looks survive stat-gear swaps, ownership fails closed, and the grant hook is store/drop agnostic.

const CharacterManager = preload("res://scripts/character_manager.gd")
const WardrobeOps = preload("res://scripts/wardrobe_ops.gd")

var _cid: int


func before_each() -> void:
	CharacterManager.reset_for_test()
	WardrobeOps.reset_for_test()
	CharacterManager.ensure_character("dresser")
	_cid = int(CharacterManager.get_character("dresser")["id"])
	CharacterManager.add_item_to_bag(_cid, "itm_iron_sword", 1, 0)
	CharacterManager.try_equip(
		_cid, 0, {"itm_iron_sword": {"slot": "weapon", "stackable": false, "armor_type": "none"}}
	)


func _appearance() -> Dictionary:
	return {
		"id": "cos_gilded_blade",
		"display_item": "itm_iron_sword",
		"slot": "weapon",
		"armor_type": "none",
		"dye_mask": "all",
	}


func test_apply_requires_persisted_unlock_and_never_changes_stat_item() -> void:
	var denied := WardrobeOps.op(
		{"username": "dresser", "action": "apply", "slot": "weapon", "appearance": _appearance()}
	)
	assert_eq(denied.get("reason"), "not_unlocked")
	WardrobeOps.grant_unlock(_cid, "cos_gilded_blade")
	var before: Array = CharacterManager.get_inventory(_cid).duplicate(true)
	var result := (
		WardrobeOps
		. op(
			{
				"username": "dresser",
				"action": "apply",
				"slot": "weapon",
				"appearance": _appearance(),
				"dye": {"id": "dye_crimson", "color": "#9f3142"},
			}
		)
	)
	assert_true(result["ok"])
	assert_eq(CharacterManager.get_inventory(_cid), before, "raw stat inventory is byte-identical")
	var decorated: Array = result["slots"]
	assert_eq(decorated[0]["item_id"], "itm_iron_sword", "real stat item remains")
	assert_eq(decorated[0]["appearance_override"], "itm_iron_sword", "display channel overlays")
	assert_eq(decorated[0]["tint"], "#9f3142")


func test_slot_look_survives_replacing_the_stat_item() -> void:
	WardrobeOps.grant_unlock(_cid, "cos_gilded_blade")
	WardrobeOps.op(
		{"username": "dresser", "action": "apply", "slot": "weapon", "appearance": _appearance()}
	)
	var replacement := [
		{"slot_type": "weapon", "slot_index": 0, "item_id": "itm_epic_axe", "item_count": 1}
	]
	var decorated := WardrobeOps.decorate_slots(_cid, replacement)
	assert_eq(decorated[0]["item_id"], "itm_epic_axe", "new stat weapon is authoritative")
	assert_eq(
		decorated[0]["appearance_override"], "itm_iron_sword", "chosen look persists per slot"
	)


func test_hide_helm_is_a_server_toggle_and_persists_without_a_client_flag() -> void:
	var first := WardrobeOps.op({"username": "dresser", "action": "toggle_hide_helm"})
	assert_true(first["ok"])
	assert_true(first["looks"]["head"]["hidden"])
	var second := WardrobeOps.op({"username": "dresser", "action": "toggle_hide_helm"})
	assert_false(second["looks"]["head"]["hidden"])


func test_store_grant_hook_is_idempotent_and_listed() -> void:
	WardrobeOps.grant_unlock(_cid, "cos_store_coat")
	WardrobeOps.grant_unlock(_cid, "cos_store_coat")
	var listed := WardrobeOps.op({"username": "dresser", "action": "list"})
	assert_eq(listed["unlocks"].count("cos_store_coat"), 1, "direct grants land exactly once")


func test_item_acquisition_marks_only_wearable_appearances_for_persist() -> void:
	var registry := {
		"itm_hat": {"slot": "head", "stackable": false},
		"itm_ore": {"slot": "none", "stackable": true, "max_stack": 20},
	}
	var result := CharacterManager.try_add_items(
		_cid, [{"item_id": "itm_hat", "count": 1}, {"item_id": "itm_ore", "count": 1}], registry
	)
	assert_true(result["ok"])
	assert_eq(result["appearance_unlocks"], ["itm_hat"], "first acquisition exposes wearable only")
