extends "res://addons/gut/test.gd"
# T-319: server-granted class starting weapon — a character must never stand empty-handed,
# and the real equipped item (not the client placeholder) rides the T-225 gear broadcast.

const _SG = preload("res://scripts/starting_gear.gd")
const CharacterManager = preload("res://scripts/character_manager.gd")


func before_each() -> void:
	CharacterManager.reset_for_test()


# ---- pure mapping + slot builder ----


func test_weapon_for_class_maps_launch_classes() -> void:
	# Family substrings (sword/staff/mace) mirror the client's WeaponSocket GLB resolver.
	assert_true("sword" in _SG.weapon_for_class("warrior"))
	assert_true("staff" in _SG.weapon_for_class("mage"))
	assert_true("mace" in _SG.weapon_for_class("priest"))


func test_weapon_for_class_unknown_falls_open_to_a_blade() -> void:
	assert_eq(_SG.weapon_for_class(""), _SG.DEFAULT_WEAPON)
	assert_true("sword" in _SG.weapon_for_class("rogue"))


func test_with_starting_weapon_appends_equipped_weapon_slot() -> void:
	var out := _SG.with_starting_weapon([], "warrior")
	assert_eq(out.size(), 1)
	var w: Dictionary = out[0]
	assert_eq(str(w["slot_type"]), "weapon")
	assert_eq(str(w["item_id"]), "itm_starter_sword")
	assert_eq(int(w["item_count"]), 1)


func test_with_starting_weapon_is_idempotent_and_never_clobbers() -> void:
	# A looted upgrade already in the weapon slot must survive untouched.
	var looted := [{"slot_type": "weapon", "slot_index": 0, "item_id": "itm_iron_sword"}]
	var out := _SG.with_starting_weapon(looted, "mage")
	assert_eq(out.size(), 1)
	assert_eq(str((out[0] as Dictionary)["item_id"]), "itm_iron_sword")


func test_with_starting_weapon_preserves_bag_contents() -> void:
	var slots := [{"slot_type": "bag", "slot_index": 0, "item_id": "itm_wolf_pelt"}]
	var out := _SG.with_starting_weapon(slots, "priest")
	assert_eq(out.size(), 2)


# ---- CharacterManager persistence path ----


func _locked(username: String, char_class: String) -> int:
	CharacterManager.ensure_character(username)
	var cid := int(CharacterManager.get_character(username)["id"])
	CharacterManager.set_class(cid, char_class)  # T-065: locks class_locked=true
	return cid


func test_ensure_starting_weapon_grants_class_weapon_when_locked() -> void:
	var cid := _locked("mage_alice", "mage")
	var res := CharacterManager.ensure_starting_weapon(cid)
	assert_true(bool(res["granted"]))
	var gear := _equipped_weapon(cid)
	assert_eq(gear, "itm_starter_staff")


func test_ensure_starting_weapon_skips_unclassed_character() -> void:
	# Fresh character: class not locked yet — the client placeholder covers empty hands.
	CharacterManager.ensure_character("newbie")
	var cid := int(CharacterManager.get_character("newbie")["id"])
	var res := CharacterManager.ensure_starting_weapon(cid)
	assert_false(bool(res["granted"]))
	assert_eq(_equipped_weapon(cid), "")


func test_ensure_starting_weapon_idempotent_second_call_no_op() -> void:
	var cid := _locked("warrior_bob", "warrior")
	assert_true(bool(CharacterManager.ensure_starting_weapon(cid)["granted"]))
	assert_false(bool(CharacterManager.ensure_starting_weapon(cid)["granted"]))
	# Still exactly one weapon slot.
	var weapons := 0
	for s in CharacterManager.get_inventory(cid):
		if str((s as Dictionary).get("slot_type", "")) == "weapon":
			weapons += 1
	assert_eq(weapons, 1)


func test_ensure_starting_weapon_unknown_character() -> void:
	var res := CharacterManager.ensure_starting_weapon(9999)
	assert_false(bool(res["granted"]))
	assert_eq((res["slots"] as Array).size(), 0)


func _equipped_weapon(cid: int) -> String:
	for s in CharacterManager.get_inventory(cid):
		if str((s as Dictionary).get("slot_type", "")) == "weapon":
			return str((s as Dictionary).get("item_id", ""))
	return ""
