extends GutTest

# T-644 (portal #89): kill-loot grant with party fallback + hold-for-retry. Covers: the happy path
# (killer has room), the fallback path (killer full, a party member has room), and the fail-closed
# hold (nobody has room -> item held, NOT destroyed, delivered on the next grant_loot call for that
# username — the "next loot event" retry this module documents as its scoped-down T-609 idiom).

const CharacterManager = preload("res://scripts/character_manager.gd")
const _LO = preload("res://scripts/loot_ops.gd")
const _IL = preload("res://scripts/inventory_logic.gd")

const REGISTRY := {
	"itm_wolf_pelt": {"slot": "none", "stackable": true, "max_stack": 20},
	"itm_filler": {"slot": "trinket", "stackable": false, "max_stack": 1},
}


func before_each() -> void:
	CharacterManager.reset_for_test()
	_LO._reset_for_tests()


func _cid(username: String) -> int:
	CharacterManager.ensure_character(username)
	return int(CharacterManager.get_character(username)["id"])


func _bag_count(cid: int, item_id: String) -> int:
	return int(_IL.bag_item_counts(CharacterManager.get_inventory(cid)).get(item_id, 0))


func _fill_bag(cid: int) -> void:
	for i in range(_IL.BAG_SLOTS):
		CharacterManager.add_item_to_bag(cid, "itm_filler", 1, i)


func test_killer_with_room_gets_the_loot() -> void:
	var cid := _cid("alice")
	var r := (
		_LO
		. grant_or_hold(
			{
				"usernames": ["alice"],
				"items": [{"item_id": "itm_wolf_pelt", "count": 1}],
				"item_registry": REGISTRY,
				"quest_defs": {},
			}
		)
	)
	assert_true(bool(r.get("ok", false)), "killer had room")
	assert_eq(str(r.get("granted_to", "")), "alice")
	assert_false(bool(r.get("held", true)))
	assert_eq(_bag_count(cid, "itm_wolf_pelt"), 1, "the pelt landed in the killer's bag")


func test_falls_back_to_a_party_member_with_space() -> void:
	var killer_cid := _cid("bob")
	_fill_bag(killer_cid)
	var mate_cid := _cid("cara")
	var r := (
		_LO
		. grant_or_hold(
			{
				"usernames": ["bob", "cara"],
				"items": [{"item_id": "itm_wolf_pelt", "count": 1}],
				"item_registry": REGISTRY,
				"quest_defs": {},
			}
		)
	)
	assert_true(bool(r.get("ok", false)), "the party fallback had room")
	assert_eq(
		str(r.get("granted_to", "")), "cara", "fallback candidate credited, not the full killer"
	)
	assert_eq(_bag_count(killer_cid, "itm_wolf_pelt"), 0, "the full killer got nothing")
	assert_eq(_bag_count(mate_cid, "itm_wolf_pelt"), 1, "the mate with room got the drop")


func test_nobody_has_room_holds_the_drop_and_delivers_on_the_next_call() -> void:
	var killer_cid := _cid("dana")
	_fill_bag(killer_cid)
	var r := (
		_LO
		. grant_or_hold(
			{
				"usernames": ["dana"],
				"items": [{"item_id": "itm_wolf_pelt", "count": 2}],
				"item_registry": REGISTRY,
				"quest_defs": {},
			}
		)
	)
	assert_false(bool(r.get("ok", true)), "no candidate had room")
	assert_eq(str(r.get("reason", "")), "bag_full")
	assert_true(bool(r.get("held", false)), "the drop is held, not destroyed")
	assert_eq(_LO.pending_for("dana").size(), 1, "one held entry parked for dana")
	assert_eq(_bag_count(killer_cid, "itm_wolf_pelt"), 0, "nothing landed yet")

	# Free a slot, then simulate "the next loot event" — a second grant_loot call for dana.
	CharacterManager.remove_item(killer_cid, "bag", 0)
	var r2 := (
		_LO
		. grant_or_hold(
			{
				"usernames": ["dana"],
				"items": [{"item_id": "itm_wolf_pelt", "count": 1}],
				"item_registry": REGISTRY,
				"quest_defs": {},
			}
		)
	)
	assert_true(bool(r2.get("ok", false)), "the retry lands once room exists")
	assert_eq(_LO.pending_for("dana").size(), 0, "the held drop is no longer pending")
	# 2 (the originally-held stack) + 1 (this call's own drop) = 3, delivered exactly once each.
	assert_eq(_bag_count(killer_cid, "itm_wolf_pelt"), 3, "held drop + new drop both landed, once")


func test_unknown_and_blank_usernames_are_skipped_not_treated_as_room() -> void:
	var r := (
		_LO
		. grant_or_hold(
			{
				"usernames": ["", "nobody_registered"],
				"items": [{"item_id": "itm_wolf_pelt", "count": 1}],
				"item_registry": REGISTRY,
				"quest_defs": {},
			}
		)
	)
	assert_false(bool(r.get("ok", true)), "no real character in the candidate list")
	assert_eq(str(r.get("reason", "")), "bag_full")
