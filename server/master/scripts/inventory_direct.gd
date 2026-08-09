# T-428: direct single-row inventory helpers extracted from character_manager.gd before extending
# its acquisition/persist seam (that file was at the 1000-line cap). Behavior is unchanged: test
# mode mutates the injected fake store; live mode delegates one parameterized statement.

extends RefCounted


static func add_to_bag(
	character_id: int,
	item_id: String,
	count: int,
	slot_index: int,
	test_mode: bool,
	test_inventory: Dictionary,
	execute: Callable
) -> bool:
	if test_mode:
		var inventory: Array = test_inventory.get(character_id, [])
		for entry: Dictionary in inventory:
			if entry["slot_type"] == "bag" and int(entry["slot_index"]) == slot_index:
				return true
		(
			inventory
			. append(
				{
					"slot_type": "bag",
					"slot_index": slot_index,
					"item_id": item_id,
					"item_count": count,
				}
			)
		)
		test_inventory[character_id] = inventory
		return true
	return bool(
		execute.call(
			(
				"INSERT INTO inventory.character_items "
				+ "(character_id, slot_type, slot_index, item_id, item_count) "
				+ "VALUES ($1,'bag',$2,$3,$4) ON CONFLICT DO NOTHING"
			),
			[character_id, slot_index, item_id, count]
		)
	)


static func remove(
	character_id: int,
	slot_type: String,
	slot_index: int,
	test_mode: bool,
	test_inventory: Dictionary,
	execute: Callable
) -> bool:
	if test_mode:
		var inventory: Array = test_inventory.get(character_id, [])
		for index in range(inventory.size() - 1, -1, -1):
			var entry: Dictionary = inventory[index]
			if entry["slot_type"] == slot_type and int(entry["slot_index"]) == slot_index:
				inventory.remove_at(index)
		test_inventory[character_id] = inventory
		return true
	return bool(
		execute.call(
			(
				"DELETE FROM inventory.character_items "
				+ "WHERE character_id=$1 AND slot_type=$2 AND slot_index=$3"
			),
			[character_id, slot_type, slot_index]
		)
	)


# T-208 vault move, relocated here for T-507 (character_manager was back at the line cap).
static func vault_move(
	character_id: int,
	plan: Dictionary,
	test_mode: bool,
	test_inventory: Dictionary,
	execute: Callable
) -> bool:
	if test_mode:
		var inventory: Array = test_inventory.get(character_id, [])
		for entry: Dictionary in inventory:
			if (
				str(entry["slot_type"]) == str(plan["from_type"])
				and int(entry["slot_index"]) == int(plan["from_index"])
			):
				entry["slot_type"] = str(plan["to_type"])
				entry["slot_index"] = int(plan["to_index"])
				return true
		return false
	return bool(
		(
			execute
			. call(
				(
					"UPDATE inventory.character_items SET slot_type=$4, slot_index=$5 "
					+ "WHERE character_id=$1 AND slot_type=$2 AND slot_index=$3"
				),
				[
					character_id,
					str(plan["from_type"]),
					int(plan["from_index"]),
					str(plan["to_type"]),
					int(plan["to_index"]),
				]
			)
		)
	)
